# Trivy Image Scan — Jenkins Pipeline Stage (Phase 11 reference)

Command used to gate builds on critical vulnerabilities:

```bash
trivy image --severity CRITICAL --exit-code 1 <image-name>:<tag>
```

- Exit code `0` → no CRITICAL CVEs found, pipeline proceeds
- Exit code `1` → CRITICAL CVE(s) found, pipeline stage fails and blocks deployment

Verified manually against `nginx:latest` — found 5 CRITICAL CVEs (e.g. CVE-2026-6653 in libxml2), confirmed non-zero exit code.
