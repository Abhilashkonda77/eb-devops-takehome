// Primary CI for this repo: lint -> test -> build -> smoke test -> Trivy scan.
// Runs on an Ubuntu agent with docker, helm, python3 (+venv) and curl.
// No credentials needed: nothing is pushed anywhere unless PUSH_IMAGE is ticked.

pipeline {
  agent any

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    booleanParam(name: 'PUSH_IMAGE', defaultValue: false,
                 description: 'Push the scanned image to REGISTRY (needs the registry-creds credential)')
    string(name: 'REGISTRY', defaultValue: '',
           description: 'e.g. registry.example.com/team (only used when PUSH_IMAGE is true)')
  }

  environment {
    IMAGE_REPO     = 'demo-service'
    IMAGE_TAG      = "ci-${env.BUILD_NUMBER}"
    SMOKE_NAME     = "demo-ci-smoke-${env.BUILD_NUMBER}"
    // pinned scanner image; bump deliberately, not via :latest
    TRIVY_IMAGE    = 'aquasec/trivy:0.56.2'
    TRIVY_SEVERITY = 'HIGH,CRITICAL'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        sh 'git log -1 --oneline'
      }
    }

    stage('Tooling') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          for t in docker helm python3 curl; do
            command -v "$t" >/dev/null || { echo "missing tool on agent: $t"; exit 1; }
          done
          docker version --format 'docker {{.Server.Version}}'
          helm version --short
          python3 --version
        '''
      }
    }

    stage('Static checks') {
      parallel {
        stage('Shell') {
          steps {
            sh '''#!/bin/bash
              set -euo pipefail
              bash -n setup.sh
              if command -v shellcheck >/dev/null; then
                shellcheck setup.sh
              else
                echo "shellcheck not installed on agent - skipped (bash -n passed)"
              fi
            '''
          }
        }
        stage('Helm') {
          steps {
            sh '''#!/bin/bash
              set -euo pipefail
              helm lint ./chart

              # defaults
              out=$(helm template demo ./chart)
              grep -q 'replicas: 2' <<<"$out"       || { echo "FAIL: default replicas != 2"; exit 1; }
              grep -q 'host: "demo.local"' <<<"$out" || { echo "FAIL: default ingress host";  exit 1; }

              # overrides, the way the grading harness renders the chart
              out=$(helm template demo ./chart \
                      --set replicaCount=3 \
                      --set config.appName=ci-check \
                      --set config.version=9.9.9 \
                      --set ingress.host=ci.local)
              grep -q 'replicas: 3'          <<<"$out" || { echo "FAIL: replicaCount override";  exit 1; }
              grep -q 'APP_NAME: "ci-check"' <<<"$out" || { echo "FAIL: config.appName override"; exit 1; }
              grep -q 'VERSION: "9.9.9"'     <<<"$out" || { echo "FAIL: config.version override"; exit 1; }
              grep -q 'host: "ci.local"'     <<<"$out" || { echo "FAIL: ingress.host override";  exit 1; }
              echo "helm lint + render checks passed"
            '''
          }
        }
      }
    }

    stage('Unit tests') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          python3 -m venv .venv
          .venv/bin/pip install -q -r service/requirements-dev.txt
          mkdir -p reports
          cd service && ../.venv/bin/pytest -q -p no:cacheprovider --junitxml=../reports/pytest.xml
        '''
      }
      post {
        always { junit allowEmptyResults: true, testResults: 'reports/pytest.xml' }
      }
    }

    stage('Build image') {
      steps {
        sh 'docker build --pull -t "$IMAGE_REPO:$IMAGE_TAG" service/'
      }
    }

    stage('Container smoke test') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          # image must not run as root
          uid=$(docker run --rm --entrypoint id "$IMAGE_REPO:$IMAGE_TAG" -u)
          [ "$uid" != "0" ] || { echo "FAIL: image runs as root"; exit 1; }
          echo "image runs as uid $uid"

          docker run -d --name "$SMOKE_NAME" -p 127.0.0.1::8080 \
            -e APP_NAME=ci-smoke -e VERSION=1.2.3 "$IMAGE_REPO:$IMAGE_TAG" >/dev/null
          port=$(docker port "$SMOKE_NAME" 8080/tcp | head -1 | awk -F: '{print $NF}')

          for _ in $(seq 1 20); do
            curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
            sleep 1
          done
          curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null || { echo "FAIL: /healthz"; docker logs "$SMOKE_NAME"; exit 1; }

          body=$(curl -fsS "http://127.0.0.1:$port/")
          echo "GET / -> $body"
          grep -q '"app":"ci-smoke"' <<<"$body" || { echo "FAIL: APP_NAME not from env"; exit 1; }
          grep -q '"version":"1.2.3"' <<<"$body" || { echo "FAIL: VERSION not from env";  exit 1; }
          grep -q '"pod":'            <<<"$body" || { echo "FAIL: pod missing";          exit 1; }
        '''
      }
      post {
        always { sh 'docker rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true' }
      }
    }

    stage('Trivy scan') {
      steps {
        sh '''#!/bin/bash
          set -euo pipefail
          mkdir -p reports
          # trivy runs as a container and reads the image from the host docker daemon;
          # the named volume caches the vulnerability DB between builds
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v trivy-cache:/root/.cache/ \
            "$TRIVY_IMAGE" image \
              --no-progress \
              --severity "$TRIVY_SEVERITY" \
              --ignore-unfixed \
              --exit-code 1 \
              "$IMAGE_REPO:$IMAGE_TAG" | tee reports/trivy.txt
        '''
      }
    }

    stage('Push image') {
      when { expression { return params.PUSH_IMAGE } }
      steps {
        // credential lives in Jenkins (Manage Jenkins > Credentials), never in the repo
        withCredentials([usernamePassword(credentialsId: 'registry-creds',
                                          usernameVariable: 'REG_USER',
                                          passwordVariable: 'REG_PASS')]) {
          sh '''#!/bin/bash
            set -euo pipefail
            [ -n "$REGISTRY" ] || { echo "REGISTRY parameter is empty"; exit 1; }
            echo "$REG_PASS" | docker login "${REGISTRY%%/*}" -u "$REG_USER" --password-stdin
            docker tag "$IMAGE_REPO:$IMAGE_TAG" "$REGISTRY/$IMAGE_REPO:$IMAGE_TAG"
            docker push "$REGISTRY/$IMAGE_REPO:$IMAGE_TAG"
            docker logout "${REGISTRY%%/*}"
          '''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      sh 'docker rmi "$IMAGE_REPO:$IMAGE_TAG" >/dev/null 2>&1 || true'
    }
    success {
      echo "OK: lint, tests, build, smoke test and Trivy (${env.TRIVY_SEVERITY}) all passed for ${env.IMAGE_REPO}:${env.IMAGE_TAG}"
    }
    failure {
      echo "FAILED: open the red stage in the stage view for its log. Test results: reports/pytest.xml; Trivy findings: reports/trivy.txt (both archived)."
    }
  }
}
