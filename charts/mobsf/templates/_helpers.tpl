{{- define "mobsf.fullname" -}}
{{- printf "%s-mobsf" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
