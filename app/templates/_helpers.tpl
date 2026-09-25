{{/*
Common template helpers for the generic app chart.
*/}}
{{- define "app.name" -}}
{{- required "app.name is required" .Values.app.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.app.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "app.workload" -}}
{{- if and .Values.deployment.enabled .Values.statefulSet.enabled -}}
{{- fail "Only one of deployment.enabled or statefulSet.enabled can be true" -}}
{{- else if .Values.statefulSet.enabled -}}
{{- toYaml .Values.statefulSet -}}
{{- else if .Values.deployment.enabled -}}
{{- toYaml .Values.deployment -}}
{{- else -}}
{{- fail "One of deployment.enabled or statefulSet.enabled must be true" -}}
{{- end -}}
{{- end -}}

{{- define "app.workloadKind" -}}
{{- if .Values.statefulSet.enabled -}}StatefulSet{{- else -}}Deployment{{- end -}}
{{- end -}}

{{- define "app.image" -}}
{{- $workload := include "app.workload" . | fromYaml -}}
{{- required "workload image is required" $workload.image -}}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ include "app.name" . }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{- define "app.persistenceClaimName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- default (printf "%s-data" (include "app.name" .)) .Values.persistence.claimName -}}
{{- end -}}
{{- end -}}

{{- define "app.volumeMounts" -}}
{{- if .Values.persistence.enabled }}
- name: {{ .Values.persistence.volumeName }}
  mountPath: {{ .Values.persistence.mountPath }}
  {{- with .Values.persistence.subPath }}
  subPath: {{ . }}
  {{- end }}
{{- end }}
{{- with .Values.app.volumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "app.volumes" -}}
{{- if .Values.persistence.enabled }}
- name: {{ .Values.persistence.volumeName }}
  persistentVolumeClaim:
    claimName: {{ include "app.persistenceClaimName" . }}
{{- end }}
{{- with .Values.app.volumes }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "app.dataProtectionVolumeMounts" -}}
{{- with .Values.dataProtection.volumeMounts }}
{{ toYaml . }}
{{- else }}
{{- if .Values.persistence.enabled }}
- name: {{ .Values.persistence.volumeName }}
  # Always /data, independent of persistence.mountPath (which is wherever
  # the app itself expects its data) - restic-backup's own default data
  # directory is /data, so mounting it here too means RESTIC_BACKUP_DATA_DIR
  # never needs to be set.
  mountPath: /data
{{- end }}
{{- end }}
{{- end -}}

{{- define "app.waitForInitContainers" -}}
{{- $workload := include "app.workload" . | fromYaml -}}
{{- range $target := default list $workload.waitFor }}
- name: wait-for-{{ $target }}
  image: {{ $.Values.waitFor.image | quote }}
  imagePullPolicy: {{ $.Values.waitFor.imagePullPolicy }}
  command: ["sh", "-ec"]
  args:
    - |
      until nc -z {{ $target }} {{ default 5432 (get $.Values.waitFor.ports $target) }}; do
        echo "waiting for {{ $target }}"
        sleep 2
      done
{{- end }}
{{- end -}}

{{/*
Data protection job pods get their own labels - NOT app.selectorLabels,
which would put them behind the app Service (and, with scaleToZero, make
the interceptor forward requests to e.g. a running backup pod). The
component label tells backup/debug (need the database) from cleanup
(doesn't) - see the data store ScaledObjects in scale-to-zero.yaml.
*/}}
{{- define "app.dataProtectionName" -}}
{{- printf "%s-data-protection" (include "app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.dataProtectionSelectorLabels" -}}
app.kubernetes.io/name: {{ include "app.dataProtectionName" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
With scaleToZero, postgres/mysql may be stopped when a backup/debug job
starts - it wakes them (see scale-to-zero.yaml) and waits here until
they're reachable. Without scaleToZero they're always running, so nothing
to wait for.
*/}}
{{- define "app.dataProtectionWaitForInitContainers" -}}
{{- if and .Values.scaleToZero.enabled .Values.scaleToZero.dataStores.enabled }}
{{- range $store := list (dict "enabled" $.Values.postgres.enabled "name" $.Values.postgres.name "port" 5432) (dict "enabled" $.Values.mysql.enabled "name" $.Values.mysql.name "port" 3306) }}
{{- if $store.enabled }}
- name: wait-for-{{ $store.name }}
  image: {{ $.Values.waitFor.image | quote }}
  imagePullPolicy: {{ $.Values.waitFor.imagePullPolicy }}
  command: ["sh", "-ec"]
  args:
    - |
      until nc -z {{ $store.name }} {{ $store.port }}; do
        echo "waiting for {{ $store.name }}"
        sleep 2
      done
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Startup/readiness/liveness probes for a data store container, all running
the same exec check (`command`, run via sh). Every check targets TCP on
127.0.0.1, which the images' first-start init (initdb, MySQL/MariaDB
bootstrap) doesn't listen on - so readiness only passes once the real
server is up. The startup probe gives that init (or a long AOF load /
upgrade) up to 5 minutes before liveness takes over.
*/}}
{{- define "app.dataStoreProbes" -}}
{{- $exec := dict "exec" (dict "command" (list "sh" "-c" .command)) -}}
startupProbe:
  {{- toYaml $exec | nindent 2 }}
  periodSeconds: 5
  timeoutSeconds: 5
  failureThreshold: 60
readinessProbe:
  {{- toYaml $exec | nindent 2 }}
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
livenessProbe:
  {{- toYaml $exec | nindent 2 }}
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 6
{{- end -}}

{{- define "app.resticEnv" -}}
{{- with .Values.dataProtection.env }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "app.resticEnvFrom" -}}
{{- if .Values.dataProtection.repositorySecretName }}
- secretRef:
    name: {{ .Values.dataProtection.repositorySecretName | quote }}
{{- end }}
{{- with .Values.dataProtection.envFrom }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "app.podSpec" -}}
{{- $workload := include "app.workload" . | fromYaml -}}
serviceAccountName: {{ include "app.serviceAccountName" . }}
{{- with .Values.app.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.app.podSecurityContext }}
securityContext:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- if or $workload.waitFor (and .Values.dataProtection.enabled .Values.dataProtection.restore.enabled) }}
initContainers:
{{ include "app.waitForInitContainers" . | nindent 2 }}
{{- if and .Values.dataProtection.enabled .Values.dataProtection.restore.enabled }}
  - name: restic-restore
    image: {{ .Values.dataProtection.image | quote }}
    imagePullPolicy: {{ .Values.dataProtection.imagePullPolicy }}
    command: ["sh", "-ec"]
    args:
      - |
        if [ ! -d "{{ .Values.dataProtection.restore.checkPath }}" ] || [ -z "$(ls -A "{{ .Values.dataProtection.restore.checkPath }}" 2>/dev/null)" ]; then
          restic-backup restore{{- with .Values.dataProtection.restore.beforeTimestamp }} --before "{{ . }}"{{- end }}
        else
          echo "restore skipped, {{ .Values.dataProtection.restore.checkPath }} is not empty"
        fi
    {{- with (include "app.resticEnv" .) }}
    env:
{{ . | nindent 6 }}
    {{- end }}
    {{- with (include "app.resticEnvFrom" .) }}
    envFrom:
{{ . | nindent 6 }}
    {{- end }}
    {{- with (include "app.dataProtectionVolumeMounts" .) }}
    volumeMounts:
{{ . | nindent 6 }}
    {{- end }}
{{- end }}
{{- end }}
containers:
  - name: {{ include "app.name" . }}
    image: {{ include "app.image" . | quote }}
    imagePullPolicy: {{ default .Values.app.imagePullPolicy $workload.imagePullPolicy }}
    {{- with $workload.command }}
    command:
{{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with $workload.args }}
    args:
{{ toYaml . | nindent 6 }}
    {{- end }}
    ports:
      - name: http
        containerPort: {{ .Values.app.containerPort }}
        protocol: TCP
    {{- with $workload.env }}
    env:
{{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with $workload.envFrom }}
    envFrom:
{{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with (include "app.volumeMounts" .) }}
    volumeMounts:
{{ . | nindent 6 }}
    {{- end }}
    {{- with .Values.app.resources }}
    resources:
{{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.app.securityContext }}
    securityContext:
{{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.app.livenessProbe }}
    livenessProbe:
{{ toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.app.readinessProbe }}
    readinessProbe:
{{ toYaml . | nindent 6 }}
    {{- end }}
{{- with .Values.app.nodeSelector }}
nodeSelector:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.app.affinity }}
affinity:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.app.tolerations }}
tolerations:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- with (include "app.volumes" .) }}
volumes:
{{ . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "app.cleanupFlags" -}}
{{- with .Values.dataProtection.cleanup.keepHourly }} --keep-hourly {{ . }}{{- end -}}
{{- with .Values.dataProtection.cleanup.keepDaily }} --keep-daily {{ . }}{{- end -}}
{{- with .Values.dataProtection.cleanup.keepWeekly }} --keep-weekly {{ . }}{{- end -}}
{{- with .Values.dataProtection.cleanup.keepMonthly }} --keep-monthly {{ . }}{{- end -}}
{{- with .Values.dataProtection.cleanup.keepYearly }} --keep-yearly {{ . }}{{- end -}}
{{- end -}}
