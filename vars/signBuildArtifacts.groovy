// vars/signBuildArtifacts.groovy
def call(String buildDir) {
    script {
        echo "Signing build artifacts: ${buildDir}"
        
        dir(buildDir) {
            withCredentials([
                string(credentialsId: 'gpg-passphrase', variable: 'GPG_PASSPHRASE'),
                file(credentialsId: 'gpg-private-key', variable: 'GPG_KEY_FILE')
            ]) {
                sh """
                    set -euo pipefail
                    
                    # Import clé privée GPG
                    gpg --batch --yes --import "\${GPG_KEY_FILE}"
                    
                    # Configuration GPG non-interactive
                    export GPG_TTY=\$(tty)
                    echo "pinentry-mode loopback" >> ~/.gnupg/gpg.conf
                    
                    # Recherche et signature artefacts
                    find . -name "*.dll" -o -name "*.exe" -o -name "*.nupkg" | while read artifact; do
                        echo " Signing: \${artifact}"
                        
                        # Signature binaire
                        gpg --batch --yes --pinentry-mode loopback \\
                            --passphrase "\${GPG_PASSPHRASE}" \\
                            --armor --detach-sig "\${artifact}"
                        
                        # Vérification signature
                        gpg --verify "\${artifact}.asc" "\${artifact}" || {
                            echo "ERROR: Signature verification failed for \${artifact}"
                            exit 1
                        }
                        
                        echo "Successfully signed: \${artifact}"
                    done
                    
                    # Génération manifest signatures
                    cat > signatures.manifest << EOF
# Artifact Signatures Manifest
# Generated: \$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Build Hash: \${BUILD_HASH:-unknown}
# Pipeline: \${JOB_NAME:-unknown} #\${BUILD_NUMBER:-unknown}

EOF
                    find . -name "*.asc" | sort | while read sig; do
                        ARTIFACT=\${sig%.asc}
                        HASH=\$(sha256sum "\${ARTIFACT}" | cut -d' ' -f1)
                        echo "\${ARTIFACT#./}:\${HASH}" >> signatures.manifest
                    done
                    
                    # Signature du manifest
                    gpg --batch --yes --pinentry-mode loopback \\
                        --passphrase "\${GPG_PASSPHRASE}" \\
                        --clearsign signatures.manifest
                        
                    # Nettoyage clé privée
                    gpg --batch --yes --delete-secret-keys \$(gpg --list-secret-keys --with-colons | grep sec | cut -d: -f5)
                    
                    echo "All artifacts signed successfully"
                """
            }
            
            // Archive signatures avec artefacts
            archiveArtifacts artifacts: '**/*.asc,signatures.manifest.asc', fingerprint: true
        }
    }
}