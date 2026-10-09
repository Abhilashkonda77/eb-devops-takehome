# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):

**Cause** (the actual root cause, not the symptom restated):

**Fix** (what you changed, and why this over alternatives):

**How I found it** (the sequence of commands/reasoning that led you here):

---

## Defect 2

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 3

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 4

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 5

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

## Defect 6

**Symptom:**

**Cause:**

**Fix:**

**How I found it:**

---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.

## Reporter API response parsing — unresolved image limitation

- **Symptom:** The reporter logs `pod list failed: parse pod list: unexpected end of JSON input`, and its `/healthz` endpoint returns HTTP 503.
- **API verification:** A request to the Kubernetes API using the reporter ServiceAccount returned HTTP 200 and valid PodList JSON of approximately 113 KB. RBAC permission to list pods was verified.
- **Binary investigation:** In `main.(*reporter).listPods`, the disassembly shows `movq $0x400,0x10(%rax)` immediately before a call to `io.ReadAll`. This is consistent with a 1,024-byte `io.LimitedReader` being constructed for the response body. No supported configuration variable for increasing this limit has been identified.
- **Impact:** The response is larger than the apparent reader limit, which is consistent with the incomplete JSON error. This diagnosis is based on binary disassembly because the reporter source code is unavailable.
- **Status:** Unresolved with the available chart configuration. Do not claim the reporter checks pass. A confirmed fix requires inspecting the source or obtaining a corrected compatible image; the fixed image reference must remain unchanged unless the lab rules explicitly permit otherwise.
- **Assistance:** AI assistance was used to help interpret the Go binary disassembly and investigate the failure.

## Reporter API response parsing — unresolved image limitation

- **Symptom:** The reporter logs `pod list failed: parse pod list: unexpected end of JSON input`, and its `/healthz` endpoint returns HTTP 503.
- **API verification:** A request to the Kubernetes API using the reporter ServiceAccount returned HTTP 200 and valid PodList JSON of approximately 113 KB. RBAC permission to list pods was verified.
- **Binary investigation:** In `main.(*reporter).listPods`, the disassembly shows `movq $0x400,0x10(%rax)` immediately before a call to `io.ReadAll`. This is consistent with a 1,024-byte `io.LimitedReader` being constructed for the response body. No supported configuration variable for increasing this limit has been identified.
- **Impact:** The response is larger than the apparent reader limit, which is consistent with the incomplete JSON error. This diagnosis is based on binary disassembly because the reporter source code is unavailable.
- **Status:** Unresolved with the available chart configuration. Do not claim the reporter checks pass. A confirmed fix requires inspecting the source or obtaining a corrected compatible image; the fixed image reference must remain unchanged unless the lab rules explicitly permit otherwise.
- **Assistance:** AI assistance was used to help interpret the Go binary disassembly and investigate the failure.

## Reporter: 1 KiB response cap in the prebuilt image — image defect, not chart-fixable

**Symptom**

**Cause (confirmed from the binary, no source available)**
- RBAC is correct: `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` → yes.
- The API is healthy: in-cluster request with the reporter SA returns HTTP 200 and ~113 KB of valid PodList JSON.
- `main.(*reporter).listPods` writes a fixed 1024 into the LimitedReader field (`movq $0x400,0x10(%rax)`) immediately before `io.ReadAll`, with no preceding Getenv/Atoi/test/cmov guard. The body is truncated to 1 KiB, so json.Unmarshal hits end-of-input and fails.
- No environment variable controls this limit (full binary env-read scan found none).

**Fix**
- The only correct fix is a new image where listPods reads the full body (or the limit is configurable). The lab forbids changing image repo/tag, so there is no legitimate chart-level fix. Changing RBAC, memory, resource limits, or the target namespace would not address a client-side truncation and would be a symptom hack.

**How I found it**
- Verified RBAC and the raw API response, then recovered the stripped binary's function table via .gopclntab and disassembled listPods to locate the hardcoded limit.

## Reporter: 1 KiB response cap in the prebuilt image — image defect, not chart-fixable

**Symptom**


**Cause (confirmed from the binary, no source available)**
- RBAC is correct: `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` → yes.
- The API is healthy: in-cluster request with the reporter SA returns HTTP 200 and ~113 KB of valid PodList JSON.
- `main.(*reporter).listPods` writes a fixed 1024 into the LimitedReader field (`movq $0x400,0x10(%rax)`) immediately before `io.ReadAll`, with no preceding Getenv/Atoi/test/cmov guard. The body is truncated to 1 KiB, so json.Unmarshal hits end-of-input and fails.
- No environment variable controls this limit (full binary env-read scan found none).

**Fix**
- The only correct fix is a new image where listPods reads the full body (or the limit is configurable). The lab forbids changing image repo/tag, so there is no legitimate chart-level fix. Changing RBAC, memory, resource limits, or the target namespace would not address a client-side truncation and would be a symptom hack.

**How I found it**
- Verified RBAC and the raw API response, then recovered the stripped binary's function table via .gopclntab and disassembled listPods to locate the hardcoded limit.

## Defect 6 — reporter truncates the pod-list response (prebuilt-image bug, not chart-fixable)

**Symptom** (reporter pod logs; never becomes Ready, /healthz 503):

**Cause** (confirmed by binary analysis; no Go source ships with the lab):
- RBAC is correct — `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` → yes.
- The API is healthy — an in-cluster request with the reporter ServiceAccount returns HTTP 200 and ~113 KB of valid PodList JSON.
- `main.(*reporter).listPods` (0x6a36c0–0x6a3e40) sets an io.LimitedReader limit to a hardcoded 1024 bytes (`movq $0x400,0x10(%rax)`, unconditional — no Getenv/Atoi and no test/cmov guard precede it) just before io.ReadAll. The 113 KB body is truncated to 1 KiB, so json.Unmarshal fails with "unexpected end of JSON input".
- The function's call list contains net/http and io.ReadAll but NOT os.Getenv or strconv.Atoi, so no environment variable can raise the limit.

**Fix:**
- The only correct fix is a corrected image (read the full body, or make the cap configurable). The lab forbids changing image.repository/tag, so there is no legitimate chart-level fix. Changing RBAC, resources, or the target namespace would not touch a client-side truncation and would be a symptom hack, so I left the reporter failing and documented it here.

**How I found it:**
- Confirmed RBAC and the raw API response, ruling out permissions and the server.
- `go tool objdump` failed ("no symbol section") because the binary is stripped, so I recovered the function table from .gopclntab and disassembled main.(*reporter).listPods at its real address, where the fixed 1024-byte reader limit is set with no config path.
