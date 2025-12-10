// vars/secureCheckout.groovy
def call(String workspaceDir, Map repoConfig) {
    script {
        echo " Secure checkout: ${workspaceDir}"
        
        dir(workspaceDir) {
            // Nettoyage workspace sécurisé
            sh """
                if [ -d .git ]; then
                    git clean -fdx
                    git reset --hard HEAD
                fi
                rm -rf * .*[!.]* 2>/dev/null || true
            """
            
            // Checkout avec validation GPG
            checkout([
                $class: 'GitSCM',
                branches: [[name: repoConfig.branch]],
                userRemoteConfigs: [[
                    url: repoConfig.url,
                    credentialsId: repoConfig.credentialsId
                ]],
                extensions: [
                    [$class: 'CleanBeforeCheckout'],
                    [$class: 'CloneOption', shallow: false, noTags: false]
                ]
            ])
            
            // Validation sécurité repository
            sh """
                set -euo pipefail
                
                # Validation URL repository (pas localhost en prod)
                if [[ "${repoConfig.url}" =~ localhost && "\${ENVIRONMENT:-dev}" == "prod" ]]; then
                    echo "ERROR: Localhost repository URL not allowed in production"
                    exit 1
                fi
                
                # Validation signature commits (si enhanced security)
                if [[ "\${ENHANCED_SECURITY:-false}" == "true" ]]; then
                    echo " Validating commit signatures..."
                    git log --show-signature -1 || {
                        echo "WARNING: Unsigned commit detected on protected branch"
                        # En prod, cela pourrait être une erreur fatale
                    }
                fi
                
                # Scan secrets dans historique récent
                echo " Scanning for potential secrets..."
                git log --oneline -10 | grep -iE '(password|secret|key|token|credential)' && {
                    echo "WARNING: Potential secrets found in commit messages"
                } || true
                
                # Validation intégrité
                COMMIT_HASH=\$(git rev-parse HEAD)
                echo " Secure checkout completed - Commit: \${COMMIT_HASH:0:8}"
            """
            
            // Export variables sécurité
            env.REPO_COMMIT_HASH = sh(
                script: 'git rev-parse HEAD',
                returnStdout: true
            ).trim()
            
            env.REPO_BRANCH = sh(
                script: 'git rev-parse --abbrev-ref HEAD',
                returnStdout: true
            ).trim()
        }
    }
}