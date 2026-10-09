# Findings — Part 4 Debug Lab

## Summary

This document records the defects investigated in the Part 4 debug lab,
the changes made to the Helm chart, and the remaining unresolved issue.

The chart changes made during investigation include:
- Correcting the migration Job restart policy.
- Correcting the gateway backend URL namespace.
- Reducing metrics CPU resources to fit the namespace LimitRange.
- Binding the reporter RoleBinding to the reporter ServiceAccount.
- Setting a numeric non-root UID for the workloads.
- Providing writable cache storage for the worker.
- Setting the application port to 8080.

The exact number of original lab defects should be cross-checked against
the lab instructions. Related configuration changes are listed separately
here rather than assumed to be separate original defects.

## Defect 1 — Invalid migration Job restart policy

**Symptom:** The migration Job could not be created successfully.

**Cause:** The Job template used `restartPolicy: Always`, which is not
supported for a Kubernetes Job.

**Fix:** Changed the restart policy to `OnFailure` in
`broken-chart/templates/migrate-job.yaml`.

**Evidence:** Capture the actual error from `scenario.sh up` or the
Kubernetes event output. Do not insert an example error as if it were
the original terminal output.

## Defect 2 — Gateway backend URL uses the wrong namespace

**Symptom:** The gateway could not successfully reach the intended backend.

**Cause:** The configured URL used `backend.default.svc:8080`, while the
backend Service is in the `debug-lab` namespace.

**Fix:** Updated the backend URL in `broken-chart/values.yaml` to
`http://backend.debug-lab.svc:8080`.

**Verification:** Test the gateway status endpoint and inspect gateway logs.
Record the actual command output and result.

## Defect 3 — Metrics CPU settings exceed the namespace limit

**Symptom:** The metrics workload could not create its pod when its CPU
settings exceeded the namespace LimitRange.

**Cause:** The original CPU request and limit were higher than the
namespace's permitted maximum.

**Fix:** Changed the metrics CPU request to `100m` and limit to `500m`
in `broken-chart/values.yaml`.

**Verification:** Inspect the metrics Deployment and its ReplicaSet events.
Record the actual admission error and the post-fix rollout result when available.

## Defect 4 — Reporter RoleBinding targets the wrong ServiceAccount

**Symptom:** The reporter did not have the intended permissions to list pods.

**Cause:** The RoleBinding subject referred to the `default` ServiceAccount
instead of the `reporter` ServiceAccount.

**Fix:** Updated the subject in `broken-chart/templates/rbac.yaml` to
reference `reporter`.

**Verification command:**

`kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter`

Record the actual output from the command.

## Additional workload configuration fixes

These changes were made during troubleshooting. Confirm which correspond
to distinct defects in the original lab instructions before assigning them
individual defect numbers.

### Non-root container UID

Added `runAsUser: 1000` alongside `runAsNonRoot: true` in the workload
templates. Verify the image's user and the lab's security requirements
before treating this as the intended fix for a specific original defect.

### Worker writable cache

Added an `emptyDir` volume mounted at `/var/cache/app` for the worker,
so that the application has a writable location despite the read-only
root filesystem.

### Application port

Set `PORT: "8080"` in the workload environment because the chart's
Service and probes expect port 8080. Confirm the application's actual
listening port and probe results.

## Reporter issue — Pod-list JSON parsing failure

**Symptom:** The reporter logs:

`pod list failed: parse pod list: unexpected end of JSON input`

Its `/healthz` endpoint returns HTTP 503 and the reporter does not become Ready.

**Checks already performed:**
- The reporter ServiceAccount was granted permission to list pods.
- An in-cluster API request using the reporter ServiceAccount returned
  HTTP 200 and valid PodList JSON.
- The response observed during investigation was approximately 113 KB.
- Binary disassembly showed `movq $0x400,0x10(%rax)` near a call to
  `io.ReadAll` in `main.(*reporter).listPods`.

**Diagnosis:** Disassembly of `main.(*reporter).listPods` shows
`movq $0x400,0x10(%rax)` immediately before the call to `io.ReadAll`.
Disassembly of `io.(*LimitedReader).Read` confirms that the field at offset
`0x10` is used as the remaining-byte count. The value `0x400` is 1024.
The observed Kubernetes PodList response is approximately 113 KB, while
the reporter logs `unexpected end of JSON input` and returns HTTP 503.
Together, this is strong evidence that the reporter reads only the first
1024 bytes before attempting to parse the JSON response.

**Fix limitation:** No supported chart setting for this limit has been
identified. A proper fix requires a corrected application image or a
documented, supported override from the lab authors. Do not claim a
successful reporter fix or change the required image reference without
authorization.

**Status:** Unresolved at the application-image level.

## Verification status

Latest recorded run: `bash scenario.sh verify`

Result: **7 checks passed; 4 checks failed.**

Passing checks:
- Migration Job completed.
- Backend, gateway, worker, and metrics deployments are ready.
- No pods are in CrashLoopBackOff.
- Reporter ServiceAccount can list pods.

Failing checks:
- Reporter deployment is not Ready (`0/1` replicas ready).
- Backend `/healthz` check failed in the verifier.
- Gateway `/status` check failed in the verifier.
- Reporter `/report` did not return a pod count.

During separate direct in-cluster probes, the backend returned
`{"status":"ok"}` and the gateway returned a response with
`"backend":"ok"`. These results conflict with the corresponding
verifier failures, so those checks require further investigation.
The reporter logs repeatedly show
`parse pod list: unexpected end of JSON input`.

Binary disassembly showed a 1024-byte value being set near the
reporter's `io.ReadAll` call. Along with the approximately 113 KB
PodList response, this supports the truncation hypothesis. The reporter
issue remains unresolved. Do not claim the complete verification suite
passes.

## AI assistance

AI assistance was used to help investigate Kubernetes configuration,
interpret Go binary disassembly, and document troubleshooting results.
All evidence included in this file should correspond to commands actually
run during the investigation.

## Follow-up

Review the original lab instructions to ensure the documented defects map
to the expected defect count. Capture missing evidence from actual command
output where possible, then rerun the verifier and update this document.
