// vars/securityValidation.groovy
def call() {
    script {
        echo " Security Pre-validation Started"
        
        // Validation configuration sécurité
        if (!fileExists('config/security.json')) {
            error "SECURITY: config/security.json missing - Pipeline blocked"
        }
        
        // Validation tools sécurité requis
        def requiredTools = [
            'dependency-check.sh': 'OWASP Dependency Check',
            'git': 'Git security validation',
            'gpg': 'Artifact signing'
        ]
        
        requiredTools.each { tool, description ->
            def toolCheck = sh(
                script: "which ${tool} || command -v ${tool}",
                returnStatus: true
            )
            if (toolCheck != 0) {
                error "SECURITY: ${description} (${tool}) not available - Pipeline blocked"
            }
        }
        
        // Validation environnement pipeline
        def sensitiveEnvVars = ['SONAR_TOKEN', 'GPG_PRIVATE_KEY', 'SIGNING_KEY']
        def missingVars = sensitiveEnvVars.findAll { !env[it] }
        if (missingVars) {
            error "SECURITY: Missing sensitive environment variables: ${missingVars.join(', ')}"
        }
        echo "Validation environnement pipeline completed"
        // Validation branch security policy
        def protectedBranches = ['main', 'master', 'release/*']
        def currentBranch = env.BRANCH_NAME ?: 'unknown'
        if (protectedBranches.any { currentBranch.matches(it.replace('*', '.*')) }) {
            echo " Protected branch detected: ${currentBranch} - Enhanced security active"
            env.ENHANCED_SECURITY = 'true'
        }
        
        echo " Security validation completed - Pipeline authorized"
    }
}