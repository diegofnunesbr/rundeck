FROM rundeck/rundeck:5.8.0

USER root

RUN apt-get update && \
    apt-get install -y python3 python3-pip python3-venv openssh-client && \
    pip3 install ansible

USER rundeck
