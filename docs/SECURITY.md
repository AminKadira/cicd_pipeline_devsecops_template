## Tests Gitleaks (fixtures)

Pour valider les règles dans `config/gitleaks.toml` :

### Prérequis
- Gitleaks installé et disponible dans le PATH (`gitleaks version`)

### Exécution locale
```powershell
pwsh scripts/test/run-gitleaks-tests.ps1 -ConfigPath "config/gitleaks.toml" -VerboseOutput
```
- Les fixtures positives (`tests/gitleaks/fixtures/positive`) doivent déclencher des détections.
- Les fixtures négatives (`tests/gitleaks/fixtures/negative`) ne doivent produire aucune détection.

### Intégration CI (exemple Jenkins)
Ajoutez une étape qui exécute le script:
```groovy
powershell returnStatus: true, script: 'pwsh scripts/test/run-gitleaks-tests.ps1'
```
Si une non-conformité est détectée (un positif non détecté ou un négatif détecté), le script renverra une erreur.
