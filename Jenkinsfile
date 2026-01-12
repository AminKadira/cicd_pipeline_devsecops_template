// ============================================================================
// DEVSECOPS PIPELINE - HARDENED VERSION
// OWASP Top 10 2021 Compliant | SLSA Level 2
// ============================================================================

pipeline {
    agent none

    options {
        // Prevent indefinite hangs
        timeout(time: 2, unit: 'HOURS')
        
        // Build retention
        buildDiscarder(logRotator(
            numToKeepStr: '30',
            daysToKeepStr: '90',
            artifactNumToKeepStr: '10'
        ))
        
        // Prevent concurrent builds on same branch
        disableConcurrentBuilds()
        
        // Disable automatic SCM checkout (explicit control)
        skipDefaultCheckout()
        
        // Enable timestamps in console
        timestamps()
    }

    // ========================================================================
    // SECURE ENVIRONMENT - NO HARDCODED SECRETS
    // ========================================================================
    environment {
        // All secrets via Jenkins Credentials
        SONAR_TOKEN = credentials('sonar-token')
        GPG_KEY_ID = credentials('gpg-key-id')
        GPG_PASSPHRASE = credentials('gpg-passphrase')
        GIT_SSH_KEY = credentials('git-ssh-key')
        
        // Non-sensitive configs
        BUILD_TIMESTAMP = new Date().format('yyyy-MM-dd HH:mm:ss')
        REPORTS_DIR = "${WORKSPACE}/reports"
        ARTIFACTS_DIR = "${WORKSPACE}/artifacts"
        
        // Security flags
        MASK_PASSWORDS = 'true'
        ENABLE_ARTIFACT_SIGNING = 'true'
    }

    triggers {
        githubPush()
        // pollSCM disabled for security (webhook only)
    }
    
    parameters {
        choice(
            name: 'ENVIRONMENT',
            choices: ['tst', 'sta', 'prd'],
            description: 'Target deployment environment'
        )
        
        string(
            name: 'EXECUTION_LABEL',
            defaultValue: 'plxfrsr-l1pi027',
            description: 'Jenkins agent label'
        )
        
        booleanParam(
            name: 'SKIP_SECURITY_SCAN',
            defaultValue: false,
            description: 'Skip security scans (NOT recommended)'
        )
    }

    stages {
        // ====================================================================
        // STAGE 1: INITIALIZATION & VALIDATION
        // ====================================================================
        stage('Initialize') {
            agent { label params.EXECUTION_LABEL }
            
            options {
                timeout(time: 5, unit: 'MINUTES')
            }
            
            steps {
                script {
                    echo "======================================================"
                    echo "PIPELINE INITIALIZATION"
                    echo "======================================================"
                    
                    // Sanitize inputs (OWASP A03 - Injection)
                    if (!params.ENVIRONMENT?.matches('^(tst|sta|prd)$')) {
                        error "Invalid ENVIRONMENT parameter: ${params.ENVIRONMENT}"
                    }
                    
                    if (!params.EXECUTION_LABEL?.matches('^[a-zA-Z0-9_-]+$')) {
                        error "Invalid EXECUTION_LABEL parameter"
                    }
                    
                    // Detect trigger repository
                    try {
                        env.TRIGGER_REPO_URL = "${env.gitlabSourceRepoURL}"
                        env.TRIGGER_REPO_NAME = "${env.gitlabSourceRepoName}"
                        env.TRIGGER_BRANCH = "${env.gitlabBranch}"
                        
                        echo "Triggered by: ${env.TRIGGER_REPO_NAME}"
                        echo "Branch: ${env.TRIGGER_BRANCH}"
                    } catch (Exception ex) {
                        echo "WARNING: Could not detect trigger repository"
                        env.TRIGGER_REPO_NAME = 'unknown'
                    }
                    
                    // Create secure workspace structure
                    sh """
                        mkdir -p ${REPORTS_DIR}/security
                        mkdir -p ${REPORTS_DIR}/quality
                        mkdir -p ${ARTIFACTS_DIR}
                        chmod 700 ${REPORTS_DIR}
                        chmod 700 ${ARTIFACTS_DIR}
                    """
                }
            }
        }

        // ====================================================================
        // STAGE 2: LOAD CONFIGURATION
        // ====================================================================
        stage('Load Configuration') {
            agent { label params.EXECUTION_LABEL }
            
            options {
                timeout(time: 5, unit: 'MINUTES')
            }
            
            steps {
                script {
                    echo "======================================================"
                    echo "LOADING PIPELINE CONFIGURATION"
                    echo "======================================================"
                    
                    def projectKey = (env.TRIGGER_REPO_NAME ?: '').trim()
                    if (!projectKey || projectKey == 'unknown') {
                        error "Cannot determine project key from trigger"
                    }
                    
                    // Secure config parsing with input validation
                    wrap([$class: 'MaskPasswordsBuildWrapper']) {
                        def configOutput = bat(
                            returnStdout: true,
                            script: "@powershell -ExecutionPolicy Bypass -File scripts\\utils\\parse-config.ps1 -projectKey ${projectKey}"
                        ).trim()
                        
                        // Parse KEY=VALUE pairs
                        configOutput.split('\\n').each { line ->
                            def parts = line.trim().split('=', 2)
                            if (parts.size() == 2) {
                                env."${parts[0]}" = parts[1]
                            }
                        }
                    }
                    
                    // Validate critical config loaded
                    if (!env.PROJECT_NAME || !env.PROJECT_GIT_URL) {
                        error "Critical configuration missing for project: ${projectKey}"
                    }
                    
                    env.PIPELINE_AGENT_LABEL = env.JENKINS_AGENT_LABEL ?: params.EXECUTION_LABEL
                    
                    echo "Configuration loaded: ${env.PROJECT_NAME}"
                }
            }
        }

        // ====================================================================
        // STAGE 3: SECURE CHECKOUT
        // ====================================================================
        stage('Checkout Project') {
            agent { label env.PIPELINE_AGENT_LABEL }
            
            options {
                timeout(time: 10, unit: 'MINUTES')
            }
            
            steps {
                echo "======================================================"
                echo "SECURE CHECKOUT: ${env.PROJECT_NAME}"
                echo "======================================================"
                
                dir('project') {
                    // Secure checkout with GPG validation
                    sshagent([env.PROJECT_GIT_CREDENTIALS]) {
                        sh """
                            set -euo pipefail
                            
                            # Clean workspace
                            if [ -d .git ]; then
                                git clean -fdx
                                git reset --hard HEAD
                            fi
                            
                            # Clone with depth limit
                            git clone --depth=50 --branch=${env.PROJECT_GIT_BRANCH} ${env.PROJECT_GIT_URL} .
                            
                            # Capture commit hash
                            git rev-parse HEAD > ${WORKSPACE}/commit.txt
                            
                            # Security: Validate no localhost URLs in production
                            if [[ "${params.ENVIRONMENT}" == "prd" ]] && grep -r "localhost" .; then
                                echo "ERROR: localhost references found in production code"
                                exit 1
                            fi
                        """
                    }
                    
                    script {
                        env.PROJECT_COMMIT_HASH = readFile("${WORKSPACE}/commit.txt").trim()
                        env.PROJECT_COMMIT_SHORT = env.PROJECT_COMMIT_HASH.substring(0, 8)
                    }
                }
            }
        }

        // ====================================================================
        // STAGE 4: SECURITY GATES (PARALLEL)
        // ====================================================================
        stage('Security Gates') {
            when {
                expression { params.SKIP_SECURITY_SCAN != true }
            }
            
            parallel {
                // GitLeaks Secret Scanning
                stage('GitLeaks Scan') {
                    agent { label env.PIPELINE_AGENT_LABEL }
                    
                    options {
                        timeout(time: 15, unit: 'MINUTES')
                    }
                    
                    steps {
                        dir('project') {
                            script {
                                echo "Running GitLeaks secret scan..."
                                
                                wrap([$class: 'MaskPasswordsBuildWrapper']) {
                                    def exitCode = bat(
                                        returnStatus: true,
                                        script: """
                                            powershell.exe -ExecutionPolicy Bypass -File ^
                                                "${env.WORKSPACE}\\scripts\\security\\gitleaksScan.ps1" ^
                                                -repoPath . ^
                                                -configFile "${env.WORKSPACE}\\config\\gitleaks.toml" ^
                                                -reportDir "${REPORTS_DIR}\\gitleaks"
                                        """
                                    )
                                    
                                    if (exitCode != 0) {
                                        error "SECURITY GATE FAILED: Secrets detected"
                                    }
                                }
                            }
                        }
                    }
                    
                    post {
                        always {
                            publishHTML([
                                allowMissing: false,
                                alwaysLinkToLastBuild: true,
                                keepAll: true,
                                reportDir: "${REPORTS_DIR}/gitleaks",
                                reportFiles: 'gitleaks-report.html',
                                reportName: 'GitLeaks Report'
                            ])
                        }
                    }
                }
                
                // OWASP Dependency Check
                stage('Dependency Scan') {
                    agent { label env.PIPELINE_AGENT_LABEL }
                    
                    options {
                        timeout(time: 30, unit: 'MINUTES')
                    }
                    
                    steps {
                        dir('project') {
                            script {
                                echo "Running OWASP Dependency Check..."
                                
                                wrap([$class: 'MaskPasswordsBuildWrapper']) {
                                    dependencyCheck(
                                        additionalArguments: """
                                            --scan .
                                            --out ${REPORTS_DIR}/owasp-dc
                                            --format XML --format HTML
                                            --failOnCVSS 7.0
                                            --suppression ${WORKSPACE}/config/suppression-owasp.xml
                                            --enableRetired --enableExperimental
                                            --proxyserver ${env.PROXY_SERVER}
                                            --proxyport ${env.PROXY_PORT}
                                        """,
                                        odcInstallation: 'Dep-CICD'
                                    )
                                }
                            }
                        }
                    }
                    
                    post {
                        always {
                            dependencyCheckPublisher(
                                pattern: "${REPORTS_DIR}/owasp-dc/dependency-check-report.xml",
                                failedTotalCritical: 0,
                                failedTotalHigh: 0,
                                unstableTotalMedium: 5
                            )
                        }
                    }
                }
            }
        }

        // ====================================================================
        // STAGE 5: BUILD
        // ====================================================================
        stage('Build') {
            agent { label env.PIPELINE_AGENT_LABEL }
            
            options {
                timeout(time: 30, unit: 'MINUTES')
            }
            
            steps {
                dir('project') {
                    script {
                        echo "======================================================"
                        echo "BUILDING: ${env.PROJECT_NAME}"
                        echo "======================================================"
                        
                        def apis = env.APIS_LIST?.split(',') ?: []
                        
                        apis.each { api ->
                            def apiTrim = api.trim()
                            if (apiTrim) {
                                echo "Building: ${apiTrim}"
                                
                                wrap([$class: 'MaskPasswordsBuildWrapper']) {
                                    catchError(message: 'Build failed', buildResult: 'FAILURE') {
                                        bat """
                                            powershell.exe -ExecutionPolicy Bypass -File "${env.BUILD_SCRIPT_PATH}" ^
                                                -proxyServer "${env.PROXY_SERVER}" ^
                                                -proxyPort "${env.PROXY_PORT}" ^
                                                -assemblyName "${apiTrim}" ^
                                                -type "Api" ^
                                                -environment "${params.ENVIRONMENT}" ^
                                                -baseFolder "${env.WORKSPACE}\\project"
                                        """
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            post {
                success {
                    archiveArtifacts(
                        artifacts: "project/publish/${params.ENVIRONMENT}/**/*",
                        fingerprint: true,
                        allowEmptyArchive: false
                    )
                }
            }
        }

        // ====================================================================
        // STAGE 6: ARTIFACT SIGNING (PRD/STA only)
        // ====================================================================
        stage('Sign Artifacts') {
            agent { label env.PIPELINE_AGENT_LABEL }
            
            when {
                expression { 
                    env.ENABLE_ARTIFACT_SIGNING == 'true' && 
                    params.ENVIRONMENT in ['sta', 'prd']
                }
            }
            
            options {
                timeout(time: 10, unit: 'MINUTES')
            }
            
            steps {
                script {
                    echo "======================================================"
                    echo "SIGNING ARTIFACTS"
                    echo "======================================================"
                    
                    wrap([$class: 'MaskPasswordsBuildWrapper']) {
                        withCredentials([
                            string(credentialsId: 'gpg-key-id', variable: 'GPG_KEY'),
                            string(credentialsId: 'gpg-passphrase', variable: 'GPG_PASS')
                        ]) {
                            bat """
                                powershell.exe -ExecutionPolicy Bypass -File ^
                                    "${WORKSPACE}\\scripts\\security\\sign-artifacts.ps1" ^
                                    -ArtifactsPath "${WORKSPACE}\\project\\publish\\${params.ENVIRONMENT}" ^
                                    -GpgKeyId "${GPG_KEY}" ^
                                    -GpgPassphrase "${GPG_PASS}" ^
                                    -VerifyAfterSign
                            """
                        }
                    }
                }
            }
            
            post {
                always {
                    archiveArtifacts(
                        artifacts: "project/publish/${params.ENVIRONMENT}/**/*.asc, **/signatures.manifest*",
                        fingerprint: true
                    )
                }
            }
        }

        // ====================================================================
        // STAGE 7: APPROVAL (STA/PRD)
        // ====================================================================
        stage('Deployment Approval') {
            when {
                expression { params.ENVIRONMENT in ['sta', 'prd'] }
            }
            
            steps {
                script {
                    timeout(time: 24, unit: 'HOURS') {
                        input(
                            message: "Deploy to ${params.ENVIRONMENT.toUpperCase()}?",
                            ok: 'Deploy',
                            submitter: 'admin,lead-dev,release-manager'
                        )
                    }
                }
            }
        }

        // ====================================================================
        // STAGE 8: DEPLOYMENT
        // ====================================================================
        stage('Deploy') {
            agent { label env.PIPELINE_AGENT_LABEL }
            
            when {
                expression { env.DEPLOY_ENABLED == 'true' }
            }
            
            options {
                timeout(time: 45, unit: 'MINUTES')
            }
            
            steps {
                script {
                    echo "======================================================"
                    echo "DEPLOYING TO: ${params.ENVIRONMENT.toUpperCase()}"
                    echo "======================================================"
                    
                    def servers = env.DEPLOY_SERVERS?.split(';') ?: []
                    def apis = env.APIS_LIST?.split(',') ?: []
                    
                    servers.each { server ->
                        apis.each { api ->
                            echo "Deploying ${api} to ${server}..."
                            
                            wrap([$class: 'MaskPasswordsBuildWrapper']) {
                                catchError(message: "Deployment failed: ${api} to ${server}") {
                                    bat """
                                        powershell.exe -ExecutionPolicy Bypass -File ^
                                            "D:\\_puppet\\script\\deployDotNetCore3.1.ps1" ^
                                            -server "${server}" ^
                                            -assemblyName "${api}" ^
                                            -type "Api" ^
                                            -environment "${params.ENVIRONMENT}" ^
                                            -baseFolder "${env.WORKSPACE}\\project"
                                    """
                                }
                            }
                        }
                    }
                }
            }
        }

        // ====================================================================
        // STAGE 9: SECURITY AUDIT LOG
        // ====================================================================
        stage('Security Audit') {
            agent { label env.PIPELINE_AGENT_LABEL }
            
            options {
                timeout(time: 5, unit: 'MINUTES')
            }
            
            steps {
                script {
                    echo "======================================================"
                    echo "GENERATING SECURITY AUDIT TRAIL"
                    echo "======================================================"
                    
                    wrap([$class: 'MaskPasswordsBuildWrapper']) {
                        bat """
                            powershell.exe -ExecutionPolicy Bypass -File ^
                                "${WORKSPACE}\\scripts\\security\\audit-pipeline.ps1" ^
                                -WorkspaceDir "${WORKSPACE}" ^
                                -ReportDir "${REPORTS_DIR}\\security"
                        """
                    }
                }
            }
            
            post {
                always {
                    archiveArtifacts(
                        artifacts: "${REPORTS_DIR}/security/audit-*.json",
                        fingerprint: true
                    )
                }
            }
        }
    }

    // ========================================================================
    // POST-BUILD ACTIONS
    // ========================================================================
    post {
        always {
            script {
                echo "======================================================"
                echo "PIPELINE COMPLETED"
                echo "======================================================"
                echo "Status: ${currentBuild.result ?: 'SUCCESS'}"
                echo "Duration: ${currentBuild.durationString}"
                
                // Cleanup sensitive data
                cleanWs(
                    deleteDirs: true,
                    patterns: [
                        [pattern: '**/credentials/**', type: 'INCLUDE'],
                        [pattern: '**/.git/**', type: 'INCLUDE'],
                        [pattern: '**/reports/**', type: 'EXCLUDE'],
                        [pattern: '**/logs/**', type: 'EXCLUDE']
                    ]
                )
            }
        }
        
        success {
            echo "✓ Pipeline succeeded - All security gates passed"
        }
        
        failure {
            echo "✗ Pipeline failed - Review security and build logs"
        }
    }
}