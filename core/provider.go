package core

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/jsonutil"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

var errNotExternalProvider = errors.New("not external provider")

// externalProviderEntry is one candidate from either provider table. Rule wins
// the shared-name tie, matching replacement semantics in lookupExternalProvider.
type externalProviderEntry struct {
	name     string
	provider cp.Provider
	rule     bool
}

func externalProviderEntries() externalProviderEntryList {
	proxyProviders, ruleProviders := tunnel.ProvidersSnapshot(), tunnel.RuleProvidersSnapshot()
	entries := make(externalProviderEntryList, 0, len(proxyProviders)+len(ruleProviders))
	for name, provider := range proxyProviders {
		if provider.VehicleType() != cp.Compatible {
			entries = append(entries, externalProviderEntry{name: name, provider: provider})
		}
	}
	for name, provider := range ruleProviders {
		if provider.VehicleType() != cp.Compatible {
			entries = append(entries, externalProviderEntry{name: name, provider: provider, rule: true})
		}
	}
	slices.SortFunc(entries, func(a, b externalProviderEntry) int {
		if result := strings.Compare(a.name, b.name); result != 0 {
			return result
		}
		if a.rule != b.rule {
			if a.rule {
				return -1
			}
			return 1
		}
		return 0
	})
	unique := entries[:0]
	for index, entry := range entries {
		if index == 0 || entry.name != unique[len(unique)-1].name {
			unique = append(unique, entry)
		}
	}
	return unique
}

func lookupExternalProvider(name string) (cp.Provider, bool) {
	if p, exist := tunnel.RuleProvidersSnapshot()[name]; exist && p.VehicleType() != cp.Compatible {
		return p, true
	}
	if p, exist := tunnel.ProvidersSnapshot()[name]; exist && p.VehicleType() != cp.Compatible {
		return p, true
	}
	return nil, false
}

func toExternalProvider(p cp.Provider) (ExternalProvider, error) {
	switch typed := p.(type) {
	case *provider.ProxySetProvider:
		return ExternalProvider{
			Name:             typed.Name(),
			Type:             typed.Type().String(),
			VehicleType:      typed.VehicleType().String(),
			Count:            typed.Count(),
			UpdateAt:         typed.UpdatedAt().UnixMicro(),
			Path:             typed.Vehicle().Path(),
			SubscriptionInfo: typed.GetSubscriptionInfo(),
		}, nil
	case *rp.RuleSetProvider:
		return ExternalProvider{
			Name:        typed.Name(),
			Type:        typed.Type().String(),
			VehicleType: typed.VehicleType().String(),
			Count:       typed.Count(),
			UpdateAt:    typed.UpdatedAt().UnixMicro(),
			Path:        typed.Vehicle().Path(),
		}, nil
	default:
		return ExternalProvider{}, errNotExternalProvider
	}
}

func sideUpdateExternalProvider(p cp.Provider, data []byte) error {
	switch typed := p.(type) {
	case *provider.ProxySetProvider:
		_, _, err := typed.SideUpdate(data)
		return err
	case *rp.RuleSetProvider:
		_, _, err := typed.SideUpdate(data)
		return err
	default:
		return errNotExternalProvider
	}
}

func handleGetExternalProviders() externalProviderEntryList {
	return externalProviderEntries()
}

type externalProviderEntryList []externalProviderEntry

// document implements frameWriter. Entries arrive sorted and deduplicated, so
// the resources screen can turn each provider into its document bytes directly.
func (l externalProviderEntryList) document() []byte {
	buf := make([]byte, 0, len(l)*256+64)
	buf = append(buf, '[')
	emitted := false
	for _, entry := range l {
		view, err := toExternalProvider(entry.provider)
		if err != nil {
			continue
		}
		if emitted {
			buf = append(buf, ',')
		}
		buf = appendExternalProviderJSON(buf, view)
		emitted = true
	}
	return append(buf, ']')
}

func appendExternalProviderJSON(dst []byte, view ExternalProvider) []byte {
	dst = append(dst, `{"name":`...)
	dst = jsonutil.AppendString(dst, view.Name)
	dst = append(dst, `,"type":`...)
	dst = jsonutil.AppendString(dst, view.Type)
	dst = append(dst, `,"vehicle-type":`...)
	dst = jsonutil.AppendString(dst, view.VehicleType)
	dst = append(dst, `,"count":`...)
	dst = strconv.AppendInt(dst, int64(view.Count), 10)
	dst = append(dst, `,"path":`...)
	dst = jsonutil.AppendString(dst, view.Path)
	dst = append(dst, `,"update-at":`...)
	dst = strconv.AppendInt(dst, view.UpdateAt, 10)
	if view.SubscriptionInfo == nil {
		dst = append(dst, `,"subscription-info":null`...)
		return append(dst, '}')
	}
	info := view.SubscriptionInfo
	dst = append(dst, `,"subscription-info":{"Upload":`...)
	dst = strconv.AppendInt(dst, info.Upload, 10)
	dst = append(dst, `,"Download":`...)
	dst = strconv.AppendInt(dst, info.Download, 10)
	dst = append(dst, `,"Total":`...)
	dst = strconv.AppendInt(dst, info.Total, 10)
	dst = append(dst, `,"Expire":`...)
	dst = strconv.AppendInt(dst, info.Expire, 10)
	return append(dst, '}', '}')
}

func handleGetExternalProvider(params NameParams) *ExternalProvider {
	p, exist := lookupExternalProvider(params.Name)
	if !exist {
		return nil
	}
	externalProvider, err := toExternalProvider(p)
	if err != nil {
		return nil
	}
	return &externalProvider
}

const (
	geoUpdateScope      = "geo:"
	providerUpdateScope = "provider:"
)

// One update per resource at a time. The value marks a claim taken for
// mihomo's own updater through GeoUpdateHook, the only kind that hook gives
// back: its run can start and finish inside a manual update of the resource.
var updateClaims = struct {
	sync.Mutex
	fromHook map[string]bool
}{fromHook: map[string]bool{}}

func claimUpdateAs(key string, fromHook bool) bool {
	updateClaims.Lock()
	defer updateClaims.Unlock()
	if _, held := updateClaims.fromHook[key]; held {
		return false
	}
	updateClaims.fromHook[key] = fromHook
	return true
}

func claimUpdate(key string) bool {
	return claimUpdateAs(key, false)
}

func releaseUpdate(key string) {
	updateClaims.Lock()
	defer updateClaims.Unlock()
	delete(updateClaims.fromHook, key)
}

func releaseHookUpdate(key string) {
	updateClaims.Lock()
	defer updateClaims.Unlock()
	if updateClaims.fromHook[key] {
		delete(updateClaims.fromHook, key)
	}
}

type providerRequestFailure struct {
	code       string
	reason     string
	statusCode int
}

// The reason values are matched by lib/common/network_error.dart.
func classifyProviderRequestError(err error) (providerRequestFailure, bool) {
	// mihomo reports a non-2xx fetch as errors.New(resp.Status).
	message := err.Error()
	if len(message) >= 4 && message[3] == ' ' {
		status, parseErr := strconv.Atoi(message[:3])
		if parseErr == nil && status >= 100 && status <= 599 {
			return providerRequestFailure{
				code:       "request_bad_response",
				statusCode: status,
			}, true
		}
	}
	var urlError *url.Error
	var networkError net.Error
	if reason := providerRequestFailureReason(err); reason != "" ||
		errors.As(err, &urlError) ||
		errors.As(err, &networkError) {
		return providerRequestFailure{code: "request_error", reason: reason}, true
	}
	return providerRequestFailure{}, false
}

func providerRequestFailureReason(err error) string {
	var unknownAuthority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalidCertificate x509.CertificateInvalidError
	var certificateVerification *tls.CertificateVerificationError
	var recordHeader tls.RecordHeaderError
	var alert tls.AlertError
	var dnsError *net.DNSError
	var networkError net.Error
	var opError *net.OpError
	switch {
	case errors.As(err, &unknownAuthority),
		errors.As(err, &hostname),
		errors.As(err, &invalidCertificate),
		errors.As(err, &certificateVerification),
		errors.As(err, &recordHeader),
		errors.As(err, &alert):
		return "tls"
	case errors.As(err, &dnsError), errors.Is(err, resolver.ErrIPNotFound):
		return "dns"
	case errors.Is(err, context.DeadlineExceeded),
		errors.Is(err, os.ErrDeadlineExceeded),
		errors.As(err, &networkError) && networkError.Timeout():
		return "timeout"
	case errors.As(err, &opError),
		errors.Is(err, syscall.ECONNREFUSED),
		errors.Is(err, syscall.ECONNRESET),
		errors.Is(err, io.EOF),
		errors.Is(err, io.ErrUnexpectedEOF):
		return "connection"
	}
	return ""
}

func providerError(code, providerName string, err error) *MethodError {
	return &MethodError{
		Code:    code,
		Message: err.Error(),
		Details: map[string]any{"providerName": providerName},
	}
}

func providerUpdateError(providerName string, err error) *MethodError {
	if methodErr := requestMethodError(err, map[string]any{"providerName": providerName}); methodErr != nil {
		return methodErr
	}
	return providerError("provider_update_error", providerName, err)
}

func requestMethodError(err error, details map[string]any) *MethodError {
	failure, isRequest := classifyProviderRequestError(err)
	if !isRequest {
		return nil
	}
	if failure.reason != "" {
		details["reason"] = failure.reason
	}
	if failure.statusCode != 0 {
		details["statusCode"] = failure.statusCode
	}
	return &MethodError{Code: failure.code, Message: err.Error(), Details: details}
}

func updateExternalProvider(name string, update func(cp.Provider) *MethodError) error {
	p, exist := lookupExternalProvider(name)
	if !exist {
		return providerError("provider_not_found", name, errors.New("external provider does not exist"))
	}
	key := providerUpdateScope + name
	if !claimUpdate(key) {
		return providerError("provider_updating", name, errors.New("external provider is updating"))
	}
	defer releaseUpdate(key)
	if methodErr := update(p); methodErr != nil {
		return methodErr
	}
	refreshRoute()
	return nil
}

func handleUpdateExternalProvider(params NameParams) error {
	name := params.Name
	return updateExternalProvider(name, func(p cp.Provider) *MethodError {
		if err := p.Update(); err != nil {
			return providerUpdateError(name, err)
		}
		return nil
	})
}

func handleSideLoadExternalProvider(params *SideLoadParams) error {
	name := params.Name
	return updateExternalProvider(name, func(p cp.Provider) *MethodError {
		if err := sideUpdateExternalProvider(p, []byte(params.Data)); err != nil {
			return providerError("provider_update_error", name, err)
		}
		return nil
	})
}

func handleDumpRuleSet(params PathParams) (string, error) {
	buf, err := os.ReadFile(params.Path)
	if err != nil {
		return "", err
	}
	var errs []error
	for _, behavior := range []cp.RuleBehavior{cp.Domain, cp.IPCIDR} {
		var text strings.Builder
		err := rp.ConvertToMrs(buf, behavior, cp.MrsRule, &text)
		if err == nil {
			return text.String(), nil
		}
		errs = append(errs, err)
	}
	return "", errors.Join(errs...)
}

// The profile ID is an int64 rendered through strconv, so the last element can
// never carry a separator or a `..` — that is what keeps handleClearEffect from
// becoming a general-purpose privileged file deletion API.
func providerPaths(homeDir string, profileId int64) (root string, target string) {
	root = filepath.Join(homeDir, "profiles", "providers")
	return root, filepath.Join(root, strconv.FormatInt(profileId, 10))
}

func handleClearEffect(params ClearEffectParams) error {
	profileId := params.ProfileID
	if !isInit.Load() {
		return errNotInitialized
	}
	if profileId <= 0 {
		return errors.New("invalid profile id")
	}
	providersRoot, providersPath := providerPaths(constant.Path.HomeDir(), profileId)
	if err := os.RemoveAll(providersPath); err != nil {
		return err
	}
	_ = os.Remove(providersRoot)
	return nil
}