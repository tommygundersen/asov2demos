{{/*
Expand the name of the chart.
*/}}
{{- define "container-storage-mi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "container-storage-mi.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "container-storage-mi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "container-storage-mi.labels" -}}
helm.sh/chart: {{ include "container-storage-mi.chart" . }}
{{ include "container-storage-mi.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "container-storage-mi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "container-storage-mi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Generate storage account name (must be globally unique, 3-24 chars, lowercase alphanumeric)
*/}}
{{- define "container-storage-mi.storageAccountName" -}}
{{- if .Values.storageAccountName }}
{{- .Values.storageAccountName }}
{{- else }}
{{- $baseName := .Values.appName | lower | replace "-" "" | replace "_" "" }}
{{- $truncatedName := $baseName | trunc 16 }}
{{- printf "st%s%s" $truncatedName (randAlphaNum 6 | lower) }}
{{- end }}
{{- end }}

{{/*
Generate managed identity name
*/}}
{{- define "container-storage-mi.managedIdentityName" -}}
{{- printf "id-%s-storage" .Values.appName }}
{{- end }}

{{/*
Generate service account name
*/}}
{{- define "container-storage-mi.serviceAccountName" -}}
{{- printf "sa-%s" .Values.appName }}
{{- end }}

{{/*
Generate private endpoint name
*/}}
{{- define "container-storage-mi.privateEndpointName" -}}
{{- printf "pe-%s-blob" .Values.appName }}
{{- end }}

{{/*
Get service account namespace
*/}}
{{- define "container-storage-mi.serviceAccountNamespace" -}}
{{- default .Release.Namespace .Values.serviceAccountNamespace }}
{{- end }}

{{/*
Get OIDC Issuer URL from values or ConfigMap
Priority: values.oidcIssuerUrl > platform ConfigMap
*/}}
{{- define "container-storage-mi.oidcIssuerUrl" -}}
{{- if .Values.oidcIssuerUrl }}
{{- .Values.oidcIssuerUrl }}
{{- else }}
{{- $configMapName := .Values.infrastructure.platformConfigMap | default "aso-platform-config" }}
{{- $configMapNs := .Values.infrastructure.platformConfigMapNamespace | default "kube-public" }}
{{- printf "$(kubectl get configmap %s -n %s -o jsonpath='{.data.oidcIssuerUrl}')" $configMapName $configMapNs }}
{{- end }}
{{- end }}

{{/*
Get Private DNS Zone ID from values or ConfigMap
Priority: values.privateDnsZoneId > platform ConfigMap
*/}}
{{- define "container-storage-mi.privateDnsZoneId" -}}
{{- if .Values.privateDnsZoneId }}
{{- .Values.privateDnsZoneId }}
{{- else }}
{{- /* Will be populated via lookup in templates */ -}}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Get Private Endpoint Subnet ID from values or ConfigMap
Priority: values.privateEndpointSubnetId > team ConfigMap
*/}}
{{- define "container-storage-mi.privateEndpointSubnetId" -}}
{{- if .Values.privateEndpointSubnetId }}
{{- .Values.privateEndpointSubnetId }}
{{- else }}
{{- /* Will be populated via lookup in templates */ -}}
{{- "" }}
{{- end }}
{{- end }}
