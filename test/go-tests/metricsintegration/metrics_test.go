package metricsintegration

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/konflux-ci/konflux-ci/test/go-tests/pkg/metricsauth"
)

var _ = Describe("Metrics scraping", Label("metrics"), func() {
	It("scrapes all configured /metrics targets", func(ctx SpecContext) {
		Expect(metricsCatalog).NotTo(BeNil())
		Expect(metricsCatalog.Targets).NotTo(BeEmpty())

		for _, target := range metricsCatalog.Targets {
			target := target
			By("scraping " + target.ID)
			scrapeTarget(ctx, target)
		}
	})
})

func scrapeTarget(ctx SpecContext, target metricsauth.Target) {
	GinkgoHelper()
	Eventually(func(g Gomega) {
		ready, err := metricsauth.WaitForServiceEndpointsReady(ctx, kubeClient, target.Namespace, target.Service, target.Port)
		g.Expect(err).NotTo(HaveOccurred())
		g.Expect(ready).To(BeTrue(), "metrics service endpoints should be ready")
	}).WithTimeout(metricsReadyTimeout).WithPolling(metricsReadyInterval).Should(Succeed())

	token, err := metricsauth.ServiceAccountToken(ctx, kubeREST, metricsCatalog.Scraper.Namespace, metricsCatalog.Scraper.ServiceAccount)
	Expect(err).NotTo(HaveOccurred())

	pf, err := metricsauth.StartPortForward(ctx, kubeREST, metricsauth.ServiceRef{
		Namespace: target.Namespace,
		Name:      target.Service,
		Port:      target.Port,
	})
	Expect(err).NotTo(HaveOccurred())
	defer pf.Close()

	scrapeURL := metricsauth.LocalMetricsURL(pf.LocalPort(), target.Path, target.Scheme)
	result, err := metricsauth.ScrapeLocal(ctx, scrapeURL, token, target.Scheme, target.TLSInsecureSkipVerifyForScrape())
	Expect(err).NotTo(HaveOccurred())
	Expect(metricsauth.ValidatePrometheusText(result, target.BodyMustMatchAny)).To(Succeed())
}
