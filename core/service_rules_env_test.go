package core

import (
	"context"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/stretchr/testify/require"
)

// The sweep's endpoints, spelled out so a rule that asks for a different one
// fails loudly instead of quietly receiving no answer.
const (
	claudeTraceURL     = "https://claude.ai/cdn-cgi/trace"
	geminiURL          = "https://gemini.google.com"
	chatGptIosURL      = "https://ios.chat.openai.com/"
	chatGptTraceURL    = "https://chat.openai.com/cdn-cgi/trace"
	chatGptCookieURL   = "https://api.openai.com/compliance/cookie_requirements"
	youtubePremiumURL  = "https://www.youtube.com/premium?hl=en"
	spotifyRegionURL   = "https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json"
	tikTokURL          = "https://www.tiktok.com/"
	bilibiliMainURL    = "https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi"
	bilibiliGreaterURL = "https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi"
	discordRegionURL   = "https://discord.com/api/v9/auth/location-metadata"
	primeVideoURL      = "https://www.primevideo.com"
	netflixCdnURL      = "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5"
	netflixFirstURL    = "https://www.netflix.com/title/81280792"
	netflixSecondURL   = "https://www.netflix.com/title/70143836"
	netflixRegionURL   = "https://www.netflix.com/title/80018499"
	disneyDeviceURL    = "https://disney.api.edge.bamgrid.com/devices"
	disneyTokenURL     = "https://disney.api.edge.bamgrid.com/token"
	disneySessionURL   = "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql"
)

// serviceEnvFor answers the requests a rule makes out of a recorded table, so
// the rule's own branch decides which request comes next.
func serviceEnvFor(t *testing.T, answers map[string]*ProbeResult) serviceEnv {
	t.Helper()
	return serviceEnv{
		ctx:     context.Background(),
		timeout: time.Second,
		hits:    &hitRecorder{},
		request: func(req probeRequest) *ProbeResult {
			for url, answer := range answers {
				if url == req.url {
					return answer
				}
			}
			t.Fatalf("the rule asked for %s, which this test did not answer", req.url)
			return nil
		},
	}
}

func probeAnswer(code int, body string) *ProbeResult {
	return &ProbeResult{StatusCode: code, Body: body, Delay: 7}
}

// redirectedAnswer is the response of a request the host redirected somewhere
// else, which is what the final URL carries.
func redirectedAnswer(code int, final string) *ProbeResult {
	return &ProbeResult{StatusCode: code, Url: final, Delay: 7}
}

func probeRedirect(code int, location string) *ProbeResult {
	result := &ProbeResult{StatusCode: code, Delay: 7}
	result.header = http.Header{"Location": []string{location}}
	return result
}

func TestCheckClaude(t *testing.T) {
	for _, test := range []struct {
		name   string
		body   string
		status string
		region string
	}{
		{"open region", "ip=203.0.113.7\nloc=JP\n", serviceAvailable, "JP"},
		{"closed region", "loc=CN\n", serviceUnsupportedRegion, "CN"},
		{"no region", "ip=203.0.113.7\n", serviceFailed, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := checkClaude(serviceEnvFor(t, map[string]*ProbeResult{claudeTraceURL: probeAnswer(200, test.body)}))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}

	item := checkClaude(serviceEnvFor(t, map[string]*ProbeResult{claudeTraceURL: nil}))
	require.Equal(t, serviceFailed, item.Status, "an unreachable trace must fail the service, not pass it")
}

func TestCheckGemini(t *testing.T) {
	const marker = `,2,1,200,"`
	for _, test := range []struct {
		name   string
		body   string
		status string
		region string
	}{
		{"open region", marker + "USA", serviceAvailable, "US"},
		{"closed region", marker + "CHN", serviceUnsupportedRegion, "CN"},
		{"alpha three folds to the flag", marker + "JPN", serviceAvailable, "JP"},
		{"code that is not letters", marker + "12A", serviceFailed, ""},
		{"truncated code", marker + "US", serviceFailed, ""},
		{"no marker", "<html>gemini</html>", serviceFailed, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := checkGemini(serviceEnvFor(t, map[string]*ProbeResult{geminiURL: probeAnswer(200, test.body)}))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}
}

func TestCheckChatGpt(t *testing.T) {
	for _, test := range []struct {
		name   string
		ios    string
		web    string
		status string
		region string
	}{
		{"turned away as an api client", "request is not allowed. please try again later.", "", serviceAvailable, "SG"},
		{"disallowed isp", "you may be connected to a disallowed isp", "", serviceDisallowedIsp, "SG"},
		{"blocked", "sorry, you have been blocked", "", serviceBlocked, "SG"},
		{"never answered", "unexpected page", "", serviceFailed, "SG"},
		{"web rules out the region", "request is not allowed. please try again later.", "unsupported_country", serviceUnsupportedRegion, "SG"},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := checkChatGpt(serviceEnvFor(t, map[string]*ProbeResult{
				chatGptIosURL:    probeAnswer(200, test.ios),
				chatGptTraceURL:  probeAnswer(200, "loc=SG\n"),
				chatGptCookieURL: probeAnswer(200, test.web),
			}))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}

	// The trace is its own request: a failure there costs the region, not the answer.
	item := checkChatGpt(serviceEnvFor(t, map[string]*ProbeResult{
		chatGptIosURL:    probeAnswer(200, "request is not allowed. please try again later."),
		chatGptTraceURL:  probeAnswer(500, "error"),
		chatGptCookieURL: probeAnswer(200, ""),
	}))
	require.Equal(t, serviceAvailable, item.Status)
	require.Empty(t, item.Region, "a trace that never answered must not name a region")
}

func TestCheckYouTubePremium(t *testing.T) {
	for _, test := range []struct {
		name   string
		body   string
		status string
		region string
	}{
		{"country element", `<html>id="country-code"> US <`, serviceAvailable, "US"},
		{"country field", `{"GL":"US","page":"premium"}`, serviceAvailable, "US"},
		{"camel case field", `{"countryCode":"de"}`, serviceAvailable, "DE"},
		{"snake case field", `{"country_code":"it"}`, serviceAvailable, "IT"},
		{"premium in the page", "youtube premium is not available in your country", serviceUnsupportedRegion, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := checkYouTubePremium(serviceEnvFor(t, map[string]*ProbeResult{
				youtubePremiumURL: probeAnswer(200, test.body),
			}))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}

	item := checkYouTubePremium(serviceEnvFor(t, map[string]*ProbeResult{youtubePremiumURL: probeAnswer(503, "")}))
	require.Equal(t, serviceUnavailable, item.Status, "a page that is down names no region and is not available")
}

func TestCheckSpotify(t *testing.T) {
	for _, test := range []struct {
		name   string
		answer *ProbeResult
		status string
		region string
	}{
		{"country in the payload", probeAnswer(200, `{"countryCode":"JP"}`), serviceAvailable, "JP"},
		{"country in the redirect", redirectedAnswer(200, "https://www.spotify.com/jp-en/"), serviceAvailable, "JP"},
		{"forbidden", probeAnswer(http.StatusForbidden, ""), serviceUnsupportedRegion, ""},
		{"unavailable for legal reasons", probeAnswer(http.StatusUnavailableForLegalReasons, ""), serviceUnsupportedRegion, ""},
		{"server error", probeAnswer(500, ""), serviceUnavailable, ""},
		{"ruled out in the body", probeAnswer(200, "not available in your country"), serviceUnsupportedRegion, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := checkSpotify(serviceEnvFor(t, map[string]*ProbeResult{spotifyRegionURL: test.answer}))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}
}

// TikTok is not behind Cloudflare, so the region comes out of the page's app
// context rather than a trace.
func TestCheckTikTok(t *testing.T) {
	for _, test := range []struct {
		name   string
		answer *ProbeResult
		status string
		region string
	}{
		{"open region", probeAnswer(200, `"webapp.app-context":{"region":"JP"}`), serviceAvailable, "JP"},
		{"forbidden", probeAnswer(http.StatusForbidden, ""), serviceUnsupportedRegion, ""},
		{"unavailable for legal reasons", probeAnswer(http.StatusUnavailableForLegalReasons, ""), serviceUnsupportedRegion, ""},
		{"missing page", probeAnswer(404, ""), serviceFailed, ""},
		{"ruled out in the body", probeAnswer(200, "tiktok is not available"), serviceUnsupportedRegion, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			item := checkTikTok(serviceEnvFor(t, map[string]*ProbeResult{tikTokURL: test.answer}))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}
}

// The mainland episode is asked first; only a region lock sends the sweep on to
// the Hong Kong, Macau and Taiwan one.
func TestCheckBilibili(t *testing.T) {
	item := checkBilibili(serviceEnvFor(t, map[string]*ProbeResult{bilibiliMainURL: probeAnswer(200, `{"code":0}`)}))
	require.Equal(t, serviceAvailable, item.Status)
	require.Equal(t, "CN", item.Region)

	item = checkBilibili(serviceEnvFor(t, map[string]*ProbeResult{
		bilibiliMainURL:    probeAnswer(200, `{"code":-10403}`),
		bilibiliGreaterURL: probeAnswer(200, `{"code":0}`),
	}))
	require.Equal(t, serviceAvailable, item.Status, "a locked mainland episode falls through to the greater region")
	require.Empty(t, item.Region)

	item = checkBilibili(serviceEnvFor(t, map[string]*ProbeResult{bilibiliMainURL: probeAnswer(200, `{"code":-400}`)}))
	require.Equal(t, serviceFailed, item.Status, "an episode that answers with a code nobody expects fails the service")
}

func TestCheckDiscord(t *testing.T) {
	item := checkDiscord(serviceEnvFor(t, map[string]*ProbeResult{discordRegionURL: probeAnswer(200, `{"country_code":"DE"}`)}))
	require.Equal(t, serviceAvailable, item.Status)
	require.Equal(t, "DE", item.Region)

	item = checkDiscord(serviceEnvFor(t, map[string]*ProbeResult{discordRegionURL: probeAnswer(http.StatusForbidden, "")}))
	require.Equal(t, serviceRestricted, item.Status, "a turned-away client reads as restricted, not unavailable")
	require.Empty(t, item.Region)
}

func TestCheckPrimeVideo(t *testing.T) {
	item := checkPrimeVideo(serviceEnvFor(t, map[string]*ProbeResult{primeVideoURL: probeAnswer(200, "isServiceRestricted")}))
	require.Equal(t, serviceUnsupportedRegion, item.Status)

	item = checkPrimeVideo(serviceEnvFor(t, map[string]*ProbeResult{primeVideoURL: probeAnswer(200, `"currentTerritory":"JP"`)}))
	require.Equal(t, serviceAvailable, item.Status)
	require.Equal(t, "JP", item.Region)

	item = checkPrimeVideo(serviceEnvFor(t, map[string]*ProbeResult{primeVideoURL: probeAnswer(200, "browse page")}))
	require.Equal(t, serviceFailed, item.Status, "a page that names neither restriction nor region answers nothing")
}

// The CDN is asked first because a blocked CDN settles the answer without the
// title probes, which a blocked region never reached anyway.
func TestCheckNetflix(t *testing.T) {
	item := checkNetflix(serviceEnvFor(t, map[string]*ProbeResult{netflixCdnURL: probeAnswer(http.StatusForbidden, "")}))
	require.Equal(t, serviceBlocked, item.Status, "a forbidden CDN settles the answer on its own")

	item = checkNetflix(serviceEnvFor(t, map[string]*ProbeResult{
		netflixCdnURL: probeAnswer(200, `{"targets":[{"location":{"country":"US"}}]}`),
	}))
	require.Equal(t, serviceAvailable, item.Status)
	require.Equal(t, "US", item.Region)

	item = checkNetflix(serviceEnvFor(t, map[string]*ProbeResult{
		netflixCdnURL:    probeAnswer(200, "{}"),
		netflixFirstURL:  probeAnswer(http.StatusNotFound, ""),
		netflixSecondURL: probeAnswer(http.StatusNotFound, ""),
	}))
	require.Equal(t, serviceOriginalsOnly, item.Status, "a CDN without targets leaves the answer to the titles")

	require.Equal(t, serviceFailed,
		netflixFromCdn(serviceEnvFor(t, map[string]*ProbeResult{netflixCdnURL: probeAnswer(200, "not json")})).Status,
		"a CDN that answers unreadable content says nothing")
	require.Equal(t, serviceFailed,
		netflixFromCdn(serviceEnvFor(t, map[string]*ProbeResult{netflixCdnURL: nil})).Status)

	for _, test := range []struct {
		name   string
		titles map[string]*ProbeResult
		status string
		region string
	}{
		{"originals only", map[string]*ProbeResult{
			netflixFirstURL:  probeAnswer(http.StatusNotFound, ""),
			netflixSecondURL: probeAnswer(http.StatusNotFound, ""),
		}, serviceOriginalsOnly, ""},
		{"region ruled out", map[string]*ProbeResult{
			netflixFirstURL:  probeAnswer(http.StatusForbidden, ""),
			netflixSecondURL: probeAnswer(http.StatusMovedPermanently, ""),
		}, serviceUnsupportedRegion, ""},
		{"full catalogue", map[string]*ProbeResult{
			netflixFirstURL:  probeAnswer(http.StatusOK, ""),
			netflixSecondURL: probeAnswer(http.StatusNotFound, ""),
			netflixRegionURL: probeRedirect(http.StatusMovedPermanently, "https://www.netflix.com/jp-en/title/80018499"),
		}, serviceAvailable, "JP"},
		{"title page missing", map[string]*ProbeResult{
			netflixFirstURL:  probeAnswer(500, ""),
			netflixSecondURL: probeAnswer(http.StatusNotFound, ""),
		}, serviceUnavailable, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			answers := map[string]*ProbeResult{netflixCdnURL: probeAnswer(500, "")}
			for url, answer := range test.titles {
				answers[url] = answer
			}
			item := checkNetflix(serviceEnvFor(t, answers))
			require.Equal(t, test.status, item.Status)
			require.Equal(t, test.region, item.Region)
		})
	}
}

func TestNetflixRegionReadsTheRedirectItWasNotAllowedToFollow(t *testing.T) {
	answers := map[string]*ProbeResult{netflixRegionURL: probeRedirect(http.StatusMovedPermanently, "https://www.netflix.com/jp-en/title/80018499")}
	require.Equal(t, "JP", netflixRegion(serviceEnvFor(t, answers)))

	answers = map[string]*ProbeResult{netflixRegionURL: probeRedirect(http.StatusMovedPermanently, "https://www.netflix.com/title/80018499")}
	require.Empty(t, netflixRegion(serviceEnvFor(t, answers)), "a redirect that names no locale names no country")

	answers = map[string]*ProbeResult{netflixRegionURL: probeRedirect(http.StatusMovedPermanently, "/jp-en/title/80018499")}
	require.Empty(t, netflixRegion(serviceEnvFor(t, answers)), "a redirect without a host has no locale segment")

	answers = map[string]*ProbeResult{netflixRegionURL: probeAnswer(http.StatusOK, "")}
	require.Empty(t, netflixRegion(serviceEnvFor(t, answers)), "a request that was answered rather than redirected names none")
}

// checkDisneyPlus walks the browser hand-shake: register a device, exchange the
// assertion for a refresh token, then ask the session which region it landed in.
func TestCheckDisneyPlus(t *testing.T) {
	device := probeAnswer(200, `{"assertion":"device-assertion"}`)
	token := probeAnswer(200, `{"refresh_token":"session-refresh"}`)
	session := probeAnswer(200, `{"countryCode":"US","inSupportedLocation":true}`)

	item := checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL:  device,
		disneyTokenURL:   token,
		disneySessionURL: session,
	}))
	require.Equal(t, serviceAvailable, item.Status)
	require.Equal(t, "US", item.Region)

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL:  device,
		disneyTokenURL:   token,
		disneySessionURL: probeAnswer(200, `{"countryCode":"US","inSupportedLocation":false}`),
	}))
	require.Equal(t, serviceComingSoon, item.Status)

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL:  device,
		disneyTokenURL:   token,
		disneySessionURL: probeAnswer(200, `{"countryCode":"US"}`),
	}))
	require.Equal(t, serviceFailed, item.Status, "a session that answers neither way settles nothing")

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL:  device,
		disneyTokenURL:   token,
		disneySessionURL: probeAnswer(200, `{"inSupportedLocation":true}`),
	}))
	require.Equal(t, serviceUnavailable, item.Status, "a session that landed nowhere is unavailable")

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL: probeAnswer(http.StatusForbidden, ""),
	}))
	require.Equal(t, serviceBlocked, item.Status)

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL: probeAnswer(200, "{}"),
	}))
	require.Equal(t, serviceFailed, item.Status, "a device without an assertion has no token to exchange")

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL: device,
		disneyTokenURL:  probeAnswer(200, "{}"),
	}))
	require.Equal(t, serviceFailed, item.Status, "a token without a refresh has no session to ask")

	item = checkDisneyPlus(serviceEnvFor(t, map[string]*ProbeResult{
		disneyDeviceURL: device,
		disneyTokenURL:  probeAnswer(200, "forbidden-location"),
	}))
	require.Equal(t, serviceBlocked, item.Status)
}

// Disney rejects a request that arrives without the browser client token, so
// the sweep's merged headers have to reach every step of the hand-shake.
func TestCheckDisneyPlusSendsTheBrowserToken(t *testing.T) {
	var authorized string
	device := probeAnswer(200, `{"assertion":"device-assertion"}`)
	token := probeAnswer(200, `{"refresh_token":"session-refresh"}`)
	session := probeAnswer(200, `{"countryCode":"US","inSupportedLocation":true}`)

	env := serviceEnv{
		ctx:     context.Background(),
		timeout: time.Second,
		hits:    &hitRecorder{},
		request: func(req probeRequest) *ProbeResult {
			switch req.url {
			case disneyDeviceURL:
				authorized = req.headers["authorization"]
				return device
			case disneyTokenURL:
				return token
			default:
				return session
			}
		},
	}

	require.Equal(t, serviceAvailable, checkDisneyPlus(env).Status)
	require.Equal(t, disneyAuthHeader, authorized, "the device registration carries the browser token")
}
