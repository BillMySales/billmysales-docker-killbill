# Kill Bill with its plugins baked in: the vendor image plus
# killbill-email-notifications (emails for invoices, payments and
# cancellations; Apache-2.0). Installing plugins at build time keeps the
# running image immutable (kpm would otherwise download them at startup).
ARG KILLBILL_VERSION=0.24.21
FROM killbill/killbill:${KILLBILL_VERSION}

# 0.8.x is the series for Kill Bill 0.24.x. kpm downloads it from Maven
# Central and checks its SHA-1.
ARG EMAIL_NOTIFICATIONS_VERSION=0.8.6
RUN /opt/kpm-latest/kpm install_java_plugin email-notifications \
        --version "${EMAIL_NOTIFICATIONS_VERSION}" \
        --destination "${KB_org_killbill_osgi_bundle_install_dir}" \
    && test -f "${KB_org_killbill_osgi_bundle_install_dir}/plugins/java/killbill-email-notifications-plugin/${EMAIL_NOTIFICATIONS_VERSION}/killbill-email-notifications-plugin-${EMAIL_NOTIFICATIONS_VERSION}.jar"

LABEL org.opencontainers.image.description="Kill Bill ${KILLBILL_VERSION} with killbill-email-notifications ${EMAIL_NOTIFICATIONS_VERSION}"
