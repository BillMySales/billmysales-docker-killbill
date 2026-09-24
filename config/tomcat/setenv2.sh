# Sourced by the images' Tomcat setenv.sh (Kill Bill and Kaui).
# - Drops the options the images enable by default for development: a remote
#   debugger (JDWP, port 12345) and unauthenticated JMX (port 8000). Anyone
#   reaching them on the Docker network could run code in the JVM.
# - Adds STACK_JAVA_OPTS (extra JVM options set in compose.yaml).
# shellcheck shell=sh disable=SC2086
CATALINA_OPTS="$(printf '%s\n' ${CATALINA_OPTS} | grep -v \
    -e '^-Xrunjdwp' -e '^-Dcom\.sun\.management\.jmxremote' -e '^-Djava\.rmi\.server\.hostname' |
    tr '\n' ' ') ${STACK_JAVA_OPTS:-}"
export CATALINA_OPTS
