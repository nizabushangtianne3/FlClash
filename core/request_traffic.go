package core

import (
	"sync"
	"time"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

// mihomo announces a connection only as it opens, and has no hook for its
// close; the request list learns the traffic that follows from these reports.
const requestTrafficInterval = time.Second

// A full bulk queue drops a report; a closed request holds its connection only this many retries.
const requestTrafficCloseRetries = 5

type RequestTraffic struct {
	Id       string `json:"id"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
}

type watchedRequest struct {
	tracker  statistic.Tracker
	upload   int64
	download int64
	// The tracker is announced before the manager stores it, so a request
	// missing from the manager on its first report may still be opening.
	fresh         bool
	closedReports int
	alive bool
}

type requestTrafficWatch struct {
	mu       sync.Mutex
	requests map[statistic.Tracker]*watchedRequest
	running  bool
}

var currentRequestTraffic = requestTrafficWatch{
	requests: map[statistic.Tracker]*watchedRequest{},
}

func (w *requestTrafficWatch) add(tracker statistic.Tracker) (start bool) {
	info := tracker.Info()
	w.mu.Lock()
	defer w.mu.Unlock()
	w.requests[tracker] = &watchedRequest{
		tracker:  tracker,
		upload:   info.UploadTotal.Load(),
		download: info.DownloadTotal.Load(),
		fresh:    true,
	}
	start = !w.running
	w.running = true
	return start
}

func (w *requestTrafficWatch) collect(queue func([]RequestTraffic) (queued bool)) (watching bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	// The manager is the only witness of a close: one pass marks the requests that left it.
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if request := w.requests[tracker]; request != nil {
			request.alive = true
		}
		return true
	})

	var (
		changed         []RequestTraffic
		changedRequests []*watchedRequest
		closing         []*watchedRequest
	)
	for tracker, request := range w.requests {
		if request.closedReports > 0 || !request.fresh && !request.alive {
			request.closedReports++
			closing = append(closing, request)
		}
		request.fresh = false
		request.alive = false
		info := request.tracker.Info()
		upload, download := info.UploadTotal.Load(), info.DownloadTotal.Load()
		if upload != request.upload || download != request.download {
			changed = append(changed, RequestTraffic{Id: tracker.ID(), Upload: upload, Download: download})
			changedRequests = append(changedRequests, request)
		}
	}
	queued := len(changed) == 0 || queue(changed)
	if queued {
		for index, request := range changedRequests {
			request.upload, request.download = changed[index].Upload, changed[index].Download
		}
	}
	for _, request := range closing {
		if queued || request.closedReports > requestTrafficCloseRetries {
			delete(w.requests, request.tracker)
		}
	}
	w.running = len(w.requests) > 0
	return w.running
}

func (w *requestTrafficWatch) clear() {
	w.mu.Lock()
	defer w.mu.Unlock()
	clear(w.requests)
	w.running = false
}

func watchRequestTraffic(tracker statistic.Tracker) {
	if currentRequestTraffic.add(tracker) {
		go runRequestTrafficWatch()
	}
}

func runRequestTrafficWatch() {
	ticker := time.NewTicker(requestTrafficInterval)
	defer ticker.Stop()
	for range ticker.C {
		if !hasEventListener() {
			currentRequestTraffic.clear()
			return
		}
		watching := currentRequestTraffic.collect(
			func(changed []RequestTraffic) bool {
				return sendMessage(RequestTrafficMessage, changed)
			},
		)
		if !watching {
			return
		}
	}
}
