{{/*
Expand the name of the chart.
*/}}
{{- define "cti-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified app name.
*/}}
{{- define "cti-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cti-stack.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cti-stack
{{- end }}

{{/*
ArgoCD Application template.
Creates a standard ArgoCD Application CR with sync wave support.

Usage:
  {{ include "cti-stack.application" (dict "name" "my-app" "wave" "1" "namespace" "my-ns" "chart" "charts/my-chart" "context" $) }}

For multi-source (Azul), use the azul.yaml template directly.
*/}}
{{- define "cti-stack.application" -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  labels:
    {{- include "cti-stack.labels" .context | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "{{ .wave }}"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: {{ .context.Values.global.project }}
  source:
    repoURL: {{ .context.Values.global.repoURL }}
    targetRevision: {{ .context.Values.global.targetRevision }}
    path: {{ .chart }}
    helm:
      valueFiles:
        - values.yaml
        {{- if eq .context.Values.global.clusterProfile "k3s" }}
        - values-k3s.yaml
        {{- else if eq .context.Values.global.clusterProfile "rke2" }}
        - values-rke2.yaml
        {{- end }}
      parameters:
        - name: global.baseDomain
          value: {{ .context.Values.global.baseDomain | quote }}
        - name: global.storageClass
          value: {{ .context.Values.global.storageClass | quote }}
        - name: global.clusterIssuer
          value: {{ .context.Values.global.clusterIssuer | quote }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .namespace }}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
{{- end }}
