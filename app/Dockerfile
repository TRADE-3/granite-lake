# Reproducible release-APK build, identical on Linux/macOS/Windows.
# Flutter version must match CI (.github/workflows/ci.yml). Image ships JDK 17 + Android SDK.
#
#   DOCKER_BUILDKIT=1 docker build -f Dockerfile --secret id=secrets,src=secrets.json \
#     --target export --output type=local,dest=./out .
#   -> ./out/app-release.apk
FROM ghcr.io/cirruslabs/flutter:3.38.5 AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# secrets.json is mounted at build time only (never copied into an image layer).
RUN --mount=type=secret,id=secrets,target=/src/secrets.json \
    flutter build apk --release --dart-define-from-file=secrets.json

FROM scratch AS export
COPY --from=build /src/build/app/outputs/flutter-apk/app-release.apk /app-release.apk
