#!/usr/bin/env bash

set -e
[ -n "$DEBUG" ] && set -x

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
METADATA=${CURDIR}/../metadata.yml
FORMULA_NAME=$(cat $METADATA | python -c "import sys,yaml; print yaml.load(sys.stdin)['name']")

## Overrideable parameters
PILLARDIR=${PILLARDIR:-${CURDIR}/pillar}
BUILDDIR=${BUILDDIR:-${CURDIR}/build}
VENV_DIR=${VENV_DIR:-${BUILDDIR}/virtualenv}
DEPSDIR=${BUILDDIR}/deps

SALT_FILE_DIR=${SALT_FILE_DIR:-${BUILDDIR}/file_root}
SALT_PILLAR_DIR=${SALT_PILLAR_DIR:-${BUILDDIR}/pillar_root}
SALT_CONFIG_DIR=${SALT_CONFIG_DIR:-${BUILDDIR}/salt}
SALT_CACHE_DIR=${SALT_CACHE_DIR:-${SALT_CONFIG_DIR}/cache}

SALT_OPTS="${SALT_OPTS} --retcode-passthrough --local -c ${SALT_CONFIG_DIR} --log-file=/dev/null"

if [ "x${SALT_VERSION}" != "x" ]; then
    PIP_SALT_VERSION="==${SALT_VERSION}"
fi

## Functions
log_info() {
    echo -e "[INFO] $*"
}

log_err() {
    echo -e "[ERROR] $*" >&2
}

setup_virtualenv() {
    log_info "Setting up Python virtualenv"
    virtualenv $VENV_DIR
    source ${VENV_DIR}/bin/activate
    python -m pip install salt${PIP_SALT_VERSION}
}

setup_test_state() {
  local template_path=$1
  local state_name=$2

  [ ! -d ${BUILDDIR}/tstates/ ] && mkdir ${BUILDDIR}/tstates/
  [ ! -d ${BUILDDIR}/rfiles/ ] && mkdir ${BUILDDIR}/rfiles/

  cat << EOF > ${BUILDDIR}/tstates/${state_name}.sls

test_${state_name}_rendering:
  file.managed:
    - name: ${BUILDDIR}/rfiles/${state_name}.conf
    - template: jinja
    - source: ${template_path}
    - context:
      _data: {{ pillar.get("_data", {}) }}
    {%- if pillar.get('service_name') %}
      service_name: {{ pillar.service_name }}
    {%- endif %}
EOF
}

setup_pillar() {
    [ ! -d ${SALT_PILLAR_DIR} ] && mkdir -p ${SALT_PILLAR_DIR}
    echo "base:" > ${SALT_PILLAR_DIR}/top.sls
    local sdir
    local state_name
    local template_name
    local pillar_name

    pushd ${PILLARDIR}/
    for spath in $(find ./ -type f -name '*.sls'); do
        pillar_name=$(basename $spath | sed -e 's/.sls$//')
        sdir=$(dirname $spath | sed -e 's/^.\///g')
        template_name=$(echo $pillar_name | cut -d '-' -f 1)
        state_name=$(echo ${sdir}_${pillar_name} | sed -e 's/\//_/g')
        if ! echo $pillar_name |grep '-'; then
          setup_test_state "salt://oslo_templates/files/$sdir/$template_name.conf" "$state_name"
        fi
        echo -e "  ${state_name}:\n    - ${sdir}/${pillar_name}" >> ${SALT_PILLAR_DIR}/top.sls
    done
}

setup_salt() {
    [ ! -d ${SALT_FILE_DIR} ] && mkdir -p ${SALT_FILE_DIR}
    [ ! -d ${SALT_CONFIG_DIR} ] && mkdir -p ${SALT_CONFIG_DIR}
    [ ! -d ${SALT_CACHE_DIR} ] && mkdir -p ${SALT_CACHE_DIR}

    echo "base:" > ${SALT_FILE_DIR}/top.sls
    for pillar in ${PILLARDIR}/*.sls; do
        grep ${FORMULA_NAME}: ${pillar} &>/dev/null || continue
        state_name=$(basename ${pillar%.sls})
        echo -e "  ${state_name}:\n    - ${FORMULA_NAME}" >> ${SALT_FILE_DIR}/top.sls
    done

    cat << EOF > ${SALT_CONFIG_DIR}/minion
file_client: local
cachedir: ${SALT_CACHE_DIR}
verify_env: False
minion_id_caching: False

file_roots:
  base:
  - ${SALT_FILE_DIR}
  - ${CURDIR}/..
  - ${BUILDDIR}/tstates/
  - /usr/share/salt-formulas/env

pillar_roots:
  base:
  - ${SALT_PILLAR_DIR}
  - ${PILLARDIR}
EOF
}

fetch_dependency() {
    dep_name="$(echo $1|cut -d : -f 1)"
    dep_source="$(echo $1|cut -d : -f 2-)"
    dep_root="${DEPSDIR}/$(basename $dep_source .git)"
    dep_metadata="${dep_root}/metadata.yml"

    [ -d /usr/share/salt-formulas/env/${dep_name} ] && log_info "Dependency $dep_name already present in system-wide salt env" && return 0
    [ -d $dep_root ] && log_info "Dependency $dep_name already fetched" && return 0

    log_info "Fetching dependency $dep_name"
    [ ! -d ${DEPSDIR} ] && mkdir -p ${DEPSDIR}
    git clone $dep_source ${DEPSDIR}/$(basename $dep_source .git)
    ln -s ${dep_root}/${dep_name} ${SALT_FILE_DIR}/${dep_name}

    METADATA="${dep_metadata}" install_dependencies
}

install_dependencies() {
    grep -E "^dependencies:" ${METADATA} >/dev/null || return 0
    (python - | while read dep; do fetch_dependency "$dep"; done) << EOF
import sys,yaml
for dep in yaml.load(open('${METADATA}', 'ro'))['dependencies']:
    print '%s:%s' % (dep["name"], dep["source"])
EOF
}

clean() {
    log_info "Cleaning up ${BUILDDIR}"
    [ -d ${BUILDDIR} ] && rm -rf ${BUILDDIR} || exit 0
}

salt_run() {
    [ -e ${VENV_DIR}/bin/activate ] && source ${VENV_DIR}/bin/activate
    local cmd=''
    cmd="python $(which salt-call) ${SALT_OPTS} $*"
    log_info "$cmd"
    $cmd
}

prepare() {
    [ -d ${BUILDDIR} ] && mkdir -p ${BUILDDIR}

    which salt-call || setup_virtualenv
    setup_pillar
    setup_salt
    install_dependencies
}

run() {
    pushd ${PILLARDIR}/
    local sdir
    local sname
    local state_name
    local pillar_name
    for spath in $(find ./ -type f -name '*.sls'); do
        sname=$(basename $spath | basename $spath | sed -e 's/.sls$//')
        sdir=$(dirname $spath | sed -e 's/^.\///')
        state_name=$(echo ${sdir}_${sname} | sed -e 's/\//_/g' | cut -d '-' -f 1)
        pillar_name=$(echo ${sdir}_${sname} | sed -e 's/\//_/g')
        salt_run --id=${pillar_name} state.show_sls ${state_name} || (log_err "Show state ${state_name} with pillar ${pillar_name} failed"; exit 1)
        salt_run --id=${pillar_name} state.sls ${state_name} || (log_err "Execution of ${state_name} with_pillar ${pillar_name} failed"; exit 1)
    done
    popd
}

_atexit() {
    RETVAL=$?
    trap true INT TERM EXIT

    if [ $RETVAL -ne 0 ]; then
        log_err "Execution failed"
    else
        log_info "Execution successful"
    fi
    return $RETVAL
}

## Main
[[ "$0" != "$BASH_SOURCE"  ]] || {
  trap _atexit INT TERM EXIT

  case $1 in
      clean)
          clean
          ;;
      prepare)
          prepare
          ;;
      run)
          run
          ;;
      *)
          prepare
          run
          ;;
  esac
}
