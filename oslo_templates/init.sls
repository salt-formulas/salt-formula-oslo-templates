{%- if pillar.oslo_templates is defined %}
include:
{%- if pillar.oslo_templates.template is defined %}
- oslo_templates.template
{%- endif %}
{%- endif %}
