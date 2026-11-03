{{/*
SCI activation in the agent's init container.

The artifact is a signed release published by gardenlinux-sci. This chart only
consumes it: verify, deploy the selected extensions, merge, restart the units
those extensions own.

An empty release means trust mode. The chart owns the selection and supplies
the activation script through its bin ConfigMap, using the existing agent image.
*/}}

{{- define "sciSysext.validate" -}}
{{- $s := default dict .Values.sciSysext -}}
{{- $rel := default dict $s.release -}}
{{- $url := default "" $rel.url -}}
{{- $digest := default "" $rel.sumsDigest -}}
{{- $publicKey := default "" $s.publicKey -}}
{{- $image := default "" $s.image -}}
{{- $extensions := default (list) $s.extensions -}}
{{- if $image -}}
{{- fail "sciSysext.image is no longer used: the agent image runs the chart's activation script. Set release.url, release.sumsDigest and publicKey instead." -}}
{{- end -}}
{{- if and $digest (not (regexMatch "^[0-9a-f]{64}$" $digest)) -}}
{{- fail (printf "sciSysext.release.sumsDigest must be 64 lowercase hex characters, got %q" $digest) -}}
{{- end -}}
{{- range $extensions -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" .) -}}
{{- fail (printf "sciSysext.extensions carries an invalid extension name: %q" .) -}}
{{- end -}}
{{- end -}}
{{- if and (or $url $digest $publicKey) (not (and $url $digest $publicKey)) -}}
{{- fail "sciSysext: set release.url, release.sumsDigest and publicKey together, or leave all three empty (trust mode)" -}}
{{- end -}}
{{- if and $url (not $extensions) -}}
{{- fail "sciSysext.extensions must not be empty when release.url is set" -}}
{{- end -}}
{{- if and $url (not (regexMatch "^https?://" $url)) -}}
{{- fail "sciSysext.release.url must use HTTP or HTTPS" -}}
{{- end -}}
{{- end -}}

{{- define "sciSysext.enabled" -}}
{{- $s := default dict .Values.sciSysext -}}
{{- $rel := default dict $s.release -}}
{{- if $rel.url -}}true{{- end -}}
{{- end -}}

{{- define "sciSysext.env" -}}
- name: HOST_ROOT
  value: /host
- name: SCI_RELEASE_URL
  value: {{ .Values.sciSysext.release.url | quote }}
- name: SCI_SUMS_DIGEST
  value: {{ .Values.sciSysext.release.sumsDigest | quote }}
- name: SCI_PUBKEY
  value: {{ .Values.sciSysext.publicKey | quote }}
- name: SCI_EXTENSIONS
  value: {{ join " " .Values.sciSysext.extensions | quote }}
- name: SCI_DEADLINE
  value: "900"
{{- end -}}
