package metricsintegration

import (
	"context"
	"os"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/konflux-ci/konflux-ci/test/go-tests/pkg/metricsauth"
)

const (
	metricsReadyTimeout  = 5 * time.Minute
	metricsReadyInterval = 2 * time.Second
)

var (
	metricsCatalog *metricsauth.Catalog
	repoRoot       string
)

var _ = BeforeSuite(func() {
	Expect(initKubernetesClient()).To(Succeed())
	Expect(kubeClient).NotTo(BeNil())
	Expect(kubeREST).NotTo(BeNil())

	var err error
	repoRoot = os.Getenv("KONFLUX_REPO_ROOT")
	if repoRoot == "" {
		repoRoot, err = findRepoRoot()
		Expect(err).NotTo(HaveOccurred())
	}

	catalogPath := metricsauth.DefaultCatalogPath(repoRoot)
	metricsCatalog, err = metricsauth.LoadCatalog(catalogPath)
	Expect(err).NotTo(HaveOccurred())

	ctx := context.Background()
	rbacPath := metricsauth.DefaultScraperRBACPath(repoRoot)
	Expect(metricsauth.ApplyManifests(ctx, kubeClient, rbacPath)).To(Succeed())
})

func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "test", "fixtures", "metrics-targets.yaml")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", os.ErrNotExist
		}
		dir = parent
	}
}
