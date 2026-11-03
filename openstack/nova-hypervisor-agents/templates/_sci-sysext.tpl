{{/*
SCI sysext consumer.

The artifact is a signed release published by gardenlinux-sci. This chart only
consumes it: verify, deploy the selected extensions, merge, restart the units
those extensions own.

All keys are set together, or all stay empty. Empty means the host provides the
stack natively and no consumer container is rendered.
*/}}

{{- define "sciSysext.validate" -}}
{{- $s := default dict .Values.sciSysext -}}
{{- $rel := default dict $s.release -}}
{{- $url := default "" $rel.url -}}
{{- $digest := default "" $rel.sumsDigest -}}
{{- $publicKey := default "" $s.publicKey -}}
{{- $image := default "" $s.image -}}
{{- $extensions := default (list) $s.extensions -}}
{{- if and $digest (not (regexMatch "^[0-9a-f]{64}$" $digest)) -}}
{{- fail (printf "sciSysext.release.sumsDigest must be 64 lowercase hex characters, got %q" $digest) -}}
{{- end -}}
{{- range $extensions -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" .) -}}
{{- fail (printf "sciSysext.extensions carries an invalid extension name: %q" .) -}}
{{- end -}}
{{- end -}}
{{- if and (or $image $url $digest $publicKey $extensions) (not (and $image $url $digest $publicKey $extensions)) -}}
{{- fail "sciSysext: set image, release.url, release.sumsDigest, publicKey and extensions together, or leave all of them empty (trust mode)" -}}
{{- end -}}
{{- end -}}

{{- define "sciSysext.enabled" -}}
{{- $s := default dict .Values.sciSysext -}}
{{- $rel := default dict $s.release -}}
{{- if and $s.image $rel.url $rel.sumsDigest $s.publicKey $s.extensions -}}true{{- end -}}
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
