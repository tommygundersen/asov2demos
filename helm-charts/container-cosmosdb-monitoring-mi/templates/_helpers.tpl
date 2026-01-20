{{/*
Expand the name of the chart.
*/}}
{{- define "container-cosmosdb-monitoring.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "container-cosmosdb-monitoring.fullname" -}}
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
Common labels
*/}}
{{- define "container-cosmosdb-monitoring.labels" -}}
helm.sh/chart: {{ include "container-cosmosdb-monitoring.chart" . }}
{{ include "container-cosmosdb-monitoring.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "container-cosmosdb-monitoring.selectorLabels" -}}
app.kubernetes.io/name: {{ include "container-cosmosdb-monitoring.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "container-cosmosdb-monitoring.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Generate the Cosmos DB account name.
Uses explicit value if provided, otherwise derives from appName.
*/}}
{{- define "container-cosmosdb-monitoring.cosmosAccountName" -}}
{{- if .Values.cosmosAccountName }}
{{- .Values.cosmosAccountName | lower | trunc 44 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-cosmos" .Values.appName | lower | trunc 44 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Generate the managed identity name.
*/}}
{{- define "container-cosmosdb-monitoring.identityName" -}}
{{- printf "%s-identity" .Values.appName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Generate the Application Insights name.
*/}}
{{- define "container-cosmosdb-monitoring.appInsightsName" -}}
{{- if .Values.monitoring.appInsightsName }}
{{- .Values.monitoring.appInsightsName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-appinsights" .Values.appName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Generate the Log Analytics workspace name.
*/}}
{{- define "container-cosmosdb-monitoring.workspaceName" -}}
{{- if .Values.monitoring.workspaceName }}
{{- .Values.monitoring.workspaceName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-logs" .Values.appName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Generate the service account name.
*/}}
{{- define "container-cosmosdb-monitoring.serviceAccountName" -}}
{{- printf "%s-sa" .Values.appName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Generate the private endpoint name.
*/}}
{{- define "container-cosmosdb-monitoring.privateEndpointName" -}}
{{- printf "%s-cosmos-pe" .Values.appName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Get the private endpoint subnet ID.
Priority: 1) Explicit value, 2) Team ConfigMap, 3) Platform ConfigMap
*/}}
{{- define "container-cosmosdb-monitoring.privateEndpointSubnetId" -}}
{{- if .Values.privateEndpointSubnetId }}
{{- .Values.privateEndpointSubnetId }}
{{- else }}
{{- $teamConfig := lookup "v1" "ConfigMap" .Release.Namespace .Values.infrastructure.teamConfigMap }}
{{- if and $teamConfig $teamConfig.data (index $teamConfig.data "privateEndpointSubnetId") }}
{{- index $teamConfig.data "privateEndpointSubnetId" }}
{{- else }}
{{- $platformConfig := lookup "v1" "ConfigMap" .Values.infrastructure.platformConfigMapNamespace .Values.infrastructure.platformConfigMap }}
{{- if and $platformConfig $platformConfig.data (index $platformConfig.data "privateEndpointSubnetId") }}
{{- index $platformConfig.data "privateEndpointSubnetId" }}
{{- else }}
{{- fail "privateEndpointSubnetId must be provided either in values.yaml, team ConfigMap, or platform ConfigMap" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Get the private DNS zone ID for Cosmos DB.
Priority: 1) Explicit value, 2) Team ConfigMap, 3) Platform ConfigMap
*/}}
{{- define "container-cosmosdb-monitoring.privateDnsZoneId" -}}
{{- if .Values.privateDnsZoneId }}
{{- .Values.privateDnsZoneId }}
{{- else }}
{{- $teamConfig := lookup "v1" "ConfigMap" .Release.Namespace .Values.infrastructure.teamConfigMap }}
{{- if and $teamConfig $teamConfig.data (index $teamConfig.data "cosmosDnsZoneId") }}
{{- index $teamConfig.data "cosmosDnsZoneId" }}
{{- else }}
{{- $platformConfig := lookup "v1" "ConfigMap" .Values.infrastructure.platformConfigMapNamespace .Values.infrastructure.platformConfigMap }}
{{- if and $platformConfig $platformConfig.data (index $platformConfig.data "cosmosDnsZoneId") }}
{{- index $platformConfig.data "cosmosDnsZoneId" }}
{{- else }}
{{- fail "privateDnsZoneId (cosmosDnsZoneId) must be provided either in values.yaml, team ConfigMap, or platform ConfigMap" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Get the OIDC Issuer URL.
Priority: 1) Explicit value, 2) Platform ConfigMap
*/}}
{{- define "container-cosmosdb-monitoring.oidcIssuerUrl" -}}
{{- if .Values.oidcIssuerUrl }}
{{- .Values.oidcIssuerUrl }}
{{- else }}
{{- $platformConfig := lookup "v1" "ConfigMap" .Values.infrastructure.platformConfigMapNamespace .Values.infrastructure.platformConfigMap }}
{{- if and $platformConfig $platformConfig.data (index $platformConfig.data "oidcIssuerUrl") }}
{{- index $platformConfig.data "oidcIssuerUrl" }}
{{- else }}
{{- fail "oidcIssuerUrl must be provided either in values.yaml or platform ConfigMap" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Get the service account namespace.
Default: Release namespace
*/}}
{{- define "container-cosmosdb-monitoring.serviceAccountNamespace" -}}
{{- if .Values.serviceAccountNamespace }}
{{- .Values.serviceAccountNamespace }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{/*
Generate the workload identity subject.
Format: system:serviceaccount:<namespace>:<service-account-name>
*/}}
{{- define "container-cosmosdb-monitoring.workloadIdentitySubject" -}}
{{- printf "system:serviceaccount:%s:%s" (include "container-cosmosdb-monitoring.serviceAccountNamespace" .) (include "container-cosmosdb-monitoring.serviceAccountName" .) }}
{{- end }}

{{/*
Get OpenTelemetry auto-instrumentation annotation based on language.
*/}}
{{- define "container-cosmosdb-monitoring.otelAnnotation" -}}
{{- $lang := .Values.monitoring.autoInstrumentation.language | default "nodejs" }}
{{- if eq $lang "java" }}
instrumentation.opentelemetry.io/inject-java: "true"
{{- else if eq $lang "nodejs" }}
instrumentation.opentelemetry.io/inject-nodejs: "true"
{{- else if eq $lang "python" }}
instrumentation.opentelemetry.io/inject-python: "true"
{{- else if eq $lang "dotnet" }}
instrumentation.opentelemetry.io/inject-dotnet: "true"
{{- else }}
instrumentation.opentelemetry.io/inject-sdk: "true"
{{- end }}
{{- end }}
