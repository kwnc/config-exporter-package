AppDynamics configuration transfer - POBAL
==========================================

Full instructions: POBAL_AppD_Config_Transfer_Guide.pdf

Files in this folder
--------------------
  config-exporter-26.7.0.0-BETA.war     Config Exporter (needs Java 17 or newer)
  Start-ConfigExporter.bat              Double-click to start it on http://localhost:8282
  Copy-AppDConfig.ps1                   Exports configuration and dashboards from non-prod
                                        and imports them into prod
  POBAL_AppD_Config_Transfer_Guide.pdf  Step-by-step guide

Quick start
-----------
1. Unzip to a local folder and unblock the files (right-click > Properties > Unblock).
2. Back up both controllers with Config Exporter (guide section 4).
3. Export from non-prod and import into prod with Copy-AppDConfig.ps1
   (guide sections 5 to 7).

Logs for Config Exporter are written to the "logs" folder next to the .war file.
