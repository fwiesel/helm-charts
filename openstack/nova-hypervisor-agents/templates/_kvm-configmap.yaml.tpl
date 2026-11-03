{{- define "kvm_configmap" }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-compute
  labels:
    system: openstack
    type: configuration
    component: nova
data:
  nova-compute.conf: |
    {{- include (print .Template.BasePath "/etc/_nova-compute.conf.tpl") . | nindent 4 }}
{{- end }}
