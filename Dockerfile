# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /source

COPY global.json ./
COPY src/DefensiveSecurity.Api.csproj ./src/
RUN dotnet restore src/DefensiveSecurity.Api.csproj

COPY src/ ./src/
RUN dotnet publish src/DefensiveSecurity.Api.csproj -c Release --no-restore -o /app/publish -p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine AS runtime
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

COPY --from=build /app/publish ./
USER $APP_UID

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["wget", "-q", "-T", "2", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

ENTRYPOINT ["dotnet", "DefensiveSecurity.Api.dll"]
