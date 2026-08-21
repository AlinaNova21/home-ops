# syntax=docker/dockerfile:1
# Derived Hermes Agent image: adds trafilatura to the uv-managed venv
# (absent from the published image, which has no pip) and bundles the
# web/local-extract plugin into the immutable install tree.
ARG HERMES_VERSION
FROM nousresearch/hermes-agent:v${HERMES_VERSION}

USER root
COPY plugins/ /opt/hermes/plugins/
RUN /usr/local/bin/uv pip install --python /opt/hermes/.venv/bin/python --no-cache --disable-pip-version-check trafilatura
USER hermes
