_data:
  debug: false
  log_file: 'nova.log'
  log_dir: '/var/log/nova'
  log_config_append: '/etc/nova/loggin.conf'
  use_syslog: true
  syslog_log_facility: INFO
  app_name: 'nova'
  log_appender: true
  log_handlers:
    watchedfile:
      enabled: true
