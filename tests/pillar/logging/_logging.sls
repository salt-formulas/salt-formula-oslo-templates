_data:
  app_name: 'nova'
  log_appender: true
  log_handlers:
    watchedfile:
      enabled: true
    fluentd:
      enabled: true
    ossyslog:
      enabled: true
service_name: nova