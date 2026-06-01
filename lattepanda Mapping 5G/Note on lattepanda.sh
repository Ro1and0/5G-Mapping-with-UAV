the code is in lattepanda, this folders correspond to lattepanda folders
root
|-opt
  |-5GCSlog/logs      <-- log files with the metrics taken
  |-5GCSlog.py        <-- main code
|-tmp
  |-mm_debug.log      <-- debug of ModemManager    
  |-metrix_debug.log  <-- debug of the main code
|-home
   |-BTU
   |-GGS
|-etc
  |-systemd
    |-systemd
      |-5GCS_log.service   <-- service to run as: $ systemctl enable 5GCS_log.service 
