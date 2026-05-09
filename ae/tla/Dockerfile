FROM eclipse-temurin:17-jre

RUN apt-get update && apt-get install -y wget unzip && rm -rf /var/lib/apt/lists/*

# Download TLC (tla2tools.jar) from official tlaplus releases
RUN mkdir -p /opt/tla && \
    wget -q "https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar" \
         -O /opt/tla/tla2tools.jar

RUN mkdir -p /tla /tmp/tlc-state

WORKDIR /tla

ENTRYPOINT ["java", "-XX:+UseParallelGC", "-Djava.io.tmpdir=/tmp/tlc-state", "-cp", "/opt/tla/tla2tools.jar"]
CMD ["tlc2.TLC"]
