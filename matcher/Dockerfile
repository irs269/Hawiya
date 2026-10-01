# Étape 1 : compilation + tests (Maven, Java 17)
FROM maven:3.9-eclipse-temurin-17 AS construction
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package

# Étape 2 : exécution (JRE seulement)
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=construction /src/target/matcher.jar /app/matcher.jar
# Utilisateur non privilégié
RUN useradd --system --no-create-home matcher
USER matcher
EXPOSE 8080
CMD ["java", "-Xmx1g", "-jar", "/app/matcher.jar"]
