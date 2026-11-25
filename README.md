# Rumo (app iOS)

App de gravação de ideias para iPhone, em SwiftUI, sem dependências de terceiros.

## Compilar e instalar

Não é preciso um Mac: o GitHub Actions compila o app.

1. Faça push (ou rode o workflow **iOS** em Actions). O CI gera o projeto com XcodeGen, roda os testes no simulador e monta o `.ipa` sem assinatura.
2. Em Actions, abra a execução concluída e baixe o artefato **Rumo-ipa** (contém `Rumo.ipa`).
3. Instale o `.ipa` no iPhone com o [Sideloadly](https://sideloadly.io), usando um Apple ID. Com Apple ID gratuito o app expira em 7 dias e precisa ser reinstalado.

## Desenvolvimento

- `project.yml` descreve o projeto (XcodeGen); o `.xcodeproj` não é versionado.
- Fontes: Red Hat Display e Red Hat Text (licença OFL, em `Rumo/Resources/Fonts/OFL.txt`).
