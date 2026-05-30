FROM ghcr.io/falcondev-oss/actions-runner:latest

USER root
COPY runner.sh /runner.sh
RUN chmod +x /runner.sh
USER runner
WORKDIR /home/runner
ENTRYPOINT ["/runner.sh"]
