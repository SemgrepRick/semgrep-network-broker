package pkg

import (
	"fmt"
	"net/http"
	"time"

	log "github.com/sirupsen/logrus"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

var hasSeenSuccessfulHeartbeat bool
var lastSuccessfulHeartbeat time.Time

func (config *HeartbeatConfig) Start(tnet *netstack.Net, userAgent string) (func(), error) {
	ticker := time.NewTicker(time.Duration(config.IntervalSeconds) * time.Second)
	done := make(chan bool)
	failures := 0
	isBootstrapping := true

	httpClient := http.Client{
		Transport: &http.Transport{
			DialContext: tnet.DialContext,
		},
		Timeout: time.Duration(config.TimeoutSeconds) * time.Second,
	}

	execute := func() bool {
		logger := log.WithField("heartbeat_url", config.URL)
		req, err := http.NewRequest("GET", config.URL, nil)
		if err != nil {
			logger.Panic(fmt.Errorf("invalid heartbeat request: %v", err))
		}
		if userAgent != "" {
			req.Header.Set("User-Agent", userAgent)
		}
		resp, err := httpClient.Do(req)
		if err != nil || resp.StatusCode != http.StatusOK {
			failures++
			if config.PanicAfterFailureCount > 0 && failures >= config.PanicAfterFailureCount {
				log.Panicf("Heartbeat failed %v times in a row", failures)
			}
			// During bootstrap the server-side pubkey propagation may still be
			// in flight; stay quiet unless FirstHeartbeatMustSucceed is set
			// (caller will surface the error).
			if isBootstrapping && !config.FirstHeartbeatMustSucceed {
				log.Debug("heartbeat.failure (bootstrap)")
			} else if err != nil {
				log.WithField("failure_count", failures).WithError(err).Warn("heartbeat.failure")
			} else {
				log.WithField("failure_count", failures).WithField("status_code", resp.StatusCode).Warn("heartbeat.failure")
			}
			heartbeatFailureCounter.Inc()
			return false
		} else {
			if !hasSeenSuccessfulHeartbeat || failures > 0 {
				log.WithField("message", "Established connectivity with Semgrep").Info("heartbeat.success")
			} else {
				log.Debug("heartbeat.success")
			}
			failures = 0
			heartbeatSuccessCounter.Inc()
			heartbeatLastSuccessTimestamp.SetToCurrentTime()
			hasSeenSuccessfulHeartbeat = true
			lastSuccessfulHeartbeat = time.Now()
			return true
		}
	}

	// Give the Semgrep data plane a brief head start to pick up the just-registered
	// pubkey before the first heartbeat, then poll on a tight cadence until
	// propagation completes.
	time.Sleep(10 * time.Second)

	const bootstrapRetryBudget = 30 * time.Second
	const bootstrapRetryInterval = 10 * time.Second
	success := execute()
	deadline := time.Now().Add(bootstrapRetryBudget)
	for !success && time.Now().Before(deadline) {
		time.Sleep(bootstrapRetryInterval)
		success = execute()
	}
	isBootstrapping = false

	if config.FirstHeartbeatMustSucceed && !success {
		return nil, fmt.Errorf("first heartbeat did not succeed")
	}

	// Align the regular cadence with when we finished bootstrapping, not with
	// process start, so the next heartbeat is IntervalSeconds from now.
	ticker.Reset(time.Duration(config.IntervalSeconds) * time.Second)
	go func() {
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				execute()
			}
		}
	}()

	return func() {
		done <- true
	}, nil
}
