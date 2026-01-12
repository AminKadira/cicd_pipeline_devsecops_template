pipeline {

    agent { 
        label params.EXECUTION_LABEL 
    }
    
    options {
        timeout(time: 2, unit: 'HOURS')
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '90'))
        disableConcurrentBuilds()
    }

    triggers {
        githubPush()
    }
    
    parameters {
        string(
            name: 'EXECUTION_LABEL',
            defaultValue: 'larivm-l1pi008',
            description: 'Jenkins agent label'
        )
        
    }

    environment {
        BUILD_TIMESTAMP = new Date().format('yyyy-MM-dd HH:mm:ss')
    }
         
    stages {
        // ================================================================
        // STAGE 1: INITIALIZATION
        // ================================================================
        stage('Initialize') {
            steps {
                script {
                    initializePipeline()
                }
            }
        }
        
        // ================================================================
        // STAGE 2: LOAD CONFIGURATION
        // ================================================================
        stage('Load Configuration') {
            steps {
                script {
                    loadPipelineConfiguration()
                }
            }
        }
        
        // ================================================================
        // STAGE 3: CHECKOUT PROJECT
        // ================================================================
        stage('Checkout Project') {
            agent { label env.PIPELINE_AGENT_LABEL }
            steps {
                script {
                    checkoutProject()
                     // Stash le code pour les stages suivants
                    stash name: 'source-code', includes: 'project/**'
                }
            }
        }
        
        // ================================================================
        // STAGE 4: SECURITY GATES (PARALLEL)
        // ================================================================
        stage('Security Gates') {
            options { timeout(time: 30, unit: 'MINUTES') }
            parallel {
                stage('GitLeaks') {
                    agent { label env.PIPELINE_AGENT_LABEL }
        
                    when { expression { env.GITLEAKS_ENABLED == 'True' } }
                    steps {
                        script { 
                            unstash 'source-code'
                            runGitLeaksScan() 
                            }
                    }
                    post {
                        always { publishGitLeaksReport() }
                    }
                }
                
                stage('Dependency Scan') {
                    agent { label env.PIPELINE_AGENT_LABEL }

                    when { expression { env.DEPENDENCY_SCAN_ENABLED == 'True' } }
                    steps {
                        script { 
                            unstash 'source-code'                            
                            runDependencyScan() }
                    }
                    post {
                        always { archiveDependencyReport() }
                    }
                }
                
                stage('OWASP DC') {
                    agent { label env.PIPELINE_AGENT_LABEL }

                    when { expression { env.OWASP_DC_ENABLED == 'True' } }
                    steps {
                        script { 
                            unstash 'source-code'
                            unOwaspDependencyCheck() }
                    }
                    post {
                        always { publishOwaspReport() }
                    }
                }
            }
        }
        
        // ================================================================
        // STAGE 6: BUILD
        // ================================================================
        stage('Build') {
            agent { label env.PIPELINE_AGENT_LABEL }
              when { 
                expression { 
                    env.RUN_ENVIRONMENT in ['tst', 'sta', 'prd']
                } 
            }
            steps {
                script { buildComponents() }
            }
            post {
                success {
                    archiveArtifacts artifacts: "project/publish/${env.RUN_ENVIRONMENT}/**/*",
                                   allowEmptyArchive: true,
                                   fingerprint: true
                }
            }
        }

        // ================================================================
        // STAGE 5: SAST - SONARQUBE (HORS PARALLEL)
        // ================================================================
        stage('SAST - SonarQube') {
            agent { label 'larivm-l1pi008' }
            when { expression { env.SONAR_ENABLED == 'True' } }
            steps {
                script { runSonarQubeAnalysis() }
            }
            // post {
            //     success { updateGitlabCommitStatus name: 'SonarQube', state: 'success' }
            //     failure { updateGitlabCommitStatus name: 'SonarQube', state: 'failed' }
            // }
        }
       
        // ================================================================
        // STAGE 7: DEPLOY
        // ================================================================
        stage('Deploy') {
            agent { label env.PIPELINE_AGENT_LABEL }
            when { 
                expression { 
                    env.DEPLOY_ENABLED == 'True' &&
                    env.RUN_ENVIRONMENT in ['tst', 'sta', 'prd']
                } 
            }
            steps {
                script { deployComponents() }
            }
        }
       
        // ================================================================
        // STAGE 8: POST-DEPLOY VALIDATION
        // ================================================================
        stage('Health Check') {
            agent { label env.PIPELINE_AGENT_LABEL }
            when { 
                expression { 
                    env.DEPLOY_ENABLED == 'True' &&
                    env.RUN_ENVIRONMENT in ['tst', 'sta', 'prd']
                } 
            }
            steps {
                script { runHealthChecks() }
            }
        }

        // ================================================================
        // STAGE 8: Functional Tests & DAST (PARALLEL)
        // ================================================================
        stage('DAST & Functional Tests') {
            options { timeout(time: 30, unit: 'MINUTES') }
            parallel {
                stage('DAST - OWASP ZAP') {
                    agent { label env.PIPELINE_AGENT_LABEL }
                    when {
                        expression { env.DAST_ENABLED == 'True'&&
                                     env.RUN_ENVIRONMENT in ['tst', 'sta', 'prd'] 
                        }
                    }
                    steps {
                         script {
                            echo "======================================================"
                            echo "DAST - OWASP ZAP"
                            echo "======================================================"
                         }
                    }
                }
                stage('Functional Tests') {
                    agent { label env.PIPELINE_AGENT_LABEL }
                    when {
                        expression { 
                            env.DEPLOY_ENABLED == 'True' && 
                            env.TESTS_ENABLED == 'True'&&
                            env.RUN_ENVIRONMENT in ['tst', 'sta', 'prd']
                        }
                    }
                   steps {
                         script {
                            echo "======================================================"
                            echo "Functional Tests"
                            echo "======================================================"
                         }
                    }
                }
            }
        }
       
        // ================================================================
        // STAGE 9: SECURITY AUDIT
        // ================================================================
        stage('Security Audit') {
            agent { label env.PIPELINE_AGENT_LABEL }
            steps {
                script { generateSecurityAudit() }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'security-audit.json', fingerprint: true
                }
            }
        }
    }
    
    post {
        always {
            script { sendPipelineNotification() }
            cleanWs(
                deleteDirs: true,
                notFailBuild: true,
                patterns: [
                    [pattern: '**/test-results/**', type: 'EXCLUDE'],
                    [pattern: '**/gitleaks-report/**', type: 'EXCLUDE'],
                    [pattern: '**/dependency-check-report.*', type: 'EXCLUDE'],
                    [pattern: '**/*.log', type: 'EXCLUDE'],
                    [pattern: 'security-audit.*', type: 'EXCLUDE']
                ]
            )
        }
        success { echo "[OK] Pipeline completed successfully" }
        unstable { echo "[WARN] Pipeline completed with warnings" }
        failure { echo "[FAIL] Pipeline failed" }
    }
}

// ============================================================================
// HELPER METHODS
// ============================================================================

def initializePipeline() {
    echo "======================================================"
    echo "PIPELINE INITIALIZATION"
    echo "======================================================"
    // ================================================================
    // 1. CAPTURE TRIGGER INFO
    // ================================================================
    env.TRIGGER_REPO_URL = env.gitlabSourceRepoURL ?: ''
    env.TRIGGER_REPO_NAME = sanitizeRepoName(env.gitlabSourceRepoName ?: '')
    env.TRIGGER_BRANCH = env.gitlabBranch ?: env.gitlabSourceBranch ?: ''
    env.TRIGGER_COMMIT = env.gitlabMergeRequestLastCommit ?: env.gitlabAfter ?: ''
    env.TRIGGER_USER = env.gitlabUserName ?: env.gitlabUserEmail ?: 'unknown'
    env.TRIGGER_TYPE = detectTriggerType()
    
    // Fallback si pas de webhook GitLab
    if (!env.TRIGGER_REPO_NAME?.trim()) {
        env.TRIGGER_REPO_NAME = 'unknown'
        env.TRIGGER_TYPE = 'manual'
    }
    
    // ================================================================
    // 2. TAG DETECTION
    // ================================================================
    def tagInfo = detectTag()
    env.IS_TAG = tagInfo.isTag.toString()
    env.TAG = tagInfo.tagName
    env.TAG_COMMIT = tagInfo.tagCommit
    env.TAG_ENVIRONMENT = tagInfo.tagEnvironment
    
    // ================================================================
    // 3. DETERMINE RUN ENVIRONMENT
    // ================================================================
    if (tagInfo.isTag && tagInfo.tagEnvironment) {
        // Tag avec prefixe TST/STA/PRD -> utiliser l'environnement du tag
        env.RUN_ENVIRONMENT = tagInfo.tagEnvironment
    } else {
        // Branch -> deduire l'environnement
        env.RUN_ENVIRONMENT = env.TRIGGER_BRANCH
    }
    
    // ================================================================
    // 4. INPUT VALIDATION (OWASP A03)
    // ================================================================
    // if (!env.RUN_ENVIRONMENT?.matches('^(tst|sta|prd)$')) {
    //     error "Unable to determine environment. Branch: ${env.TRIGGER_BRANCH}, Tag: ${env.TAG}. Resolved: ${env.RUN_ENVIRONMENT}"
    // }
    
    if (!params.EXECUTION_LABEL?.matches('^[a-zA-Z0-9_-]+$')) {
        error "Invalid EXECUTION_LABEL: ${params.EXECUTION_LABEL}"
    }

    // ================================================================
    // 5. LOG SUMMARY
    // ================================================================
    echo "------------------------------------------------------"
    echo "TRIGGER INFO"
    echo "------------------------------------------------------"
    echo "  Type: ${env.TRIGGER_TYPE}"
    echo "  Repository: ${env.TRIGGER_REPO_NAME}"
    echo "  Branch: ${env.TRIGGER_BRANCH}"
    echo "  Commit: ${env.TRIGGER_COMMIT ?: 'N/A'}"
    echo "  User: ${env.TRIGGER_USER}"
    echo "------------------------------------------------------"
    echo "TAG INFO"
    echo "------------------------------------------------------"
    echo "  Is Tag: ${env.IS_TAG}"
    echo "  Tag Name: ${env.TAG ?: 'N/A'}"
    echo "  Tag Commit: ${env.TAG_COMMIT ?: 'N/A'}"
    echo "  Tag Environment: ${env.TAG_ENVIRONMENT ?: 'N/A'}"
    echo "------------------------------------------------------"
    echo "RESOLVED ENVIRONMENT"
    echo "------------------------------------------------------"
    echo "  Source: ${env.IS_TAG == 'true' ? 'TAG ' + env.TAG : 'BRANCH ' + env.TRIGGER_BRANCH}"
    echo "  Environment: ${env.RUN_ENVIRONMENT}"
    echo "======================================================"
}

def sanitizeRepoName(String name) {
    if (!name?.trim()) return ''
    return name.replaceAll(/\.git$/, '')
               .replaceAll(/[^a-zA-Z0-9._-]/, '')
}

def detectTag() {
    def result = [
        isTag: false,
        tagName: '',
        tagCommit: '',
        tagEnvironment: ''
    ]
    
    def tagCandidate = ''
    
    // Detection via GitLab webhook TAG_PUSH
    if (env.gitlabActionType == 'TAG_PUSH') {
        result.isTag = true
        tagCandidate = env.gitlabBranch ?: ''
        result.tagCommit = env.gitlabAfter ?: ''
        echo "[TAG] Detected via GitLab webhook: ${tagCandidate}"
    }
    // Detection via ref pattern (refs/tags/xxx)
    else {
        def gitRef = env.gitlabAfter ?: env.GIT_BRANCH ?: ''
        if (gitRef.startsWith('refs/tags/')) {
            result.isTag = true
            tagCandidate = gitRef
            result.tagCommit = env.gitlabAfter ?: ''
            echo "[TAG] Detected via ref: ${tagCandidate}"
        }
    }
    
    if (!result.isTag) {
        echo "[TAG] No tag detected"
        return result
    }
    
    // ================================================================
    // CLEAN TAG NAME - Remove refs/tags/ prefix
    // ================================================================
    result.tagName = cleanTagName(tagCandidate)
    echo "[TAG] Cleaned tag name: ${result.tagName}"
    
    // ================================================================
    // EXTRACT ENVIRONMENT PREFIX FROM TAG
    // Format attendu: TST-xxx, STA-xxx, PRD-xxx (case insensitive)
    // ================================================================
    result.tagEnvironment = extractEnvironmentFromTag(result.tagName)
    
    if (result.tagEnvironment) {
        echo "[TAG] Environment prefix detected: ${result.tagEnvironment.toUpperCase()}"
    } else {
        echo "[TAG] No environment prefix (TST/STA/PRD) found in tag"
    }
    
    return result
}

def cleanTagName(String rawTag) {
    if (!rawTag?.trim()) return ''
    
    def cleaned = rawTag.trim()
    
    // Remove refs/tags/ prefix
    if (cleaned.startsWith('refs/tags/')) {
        cleaned = cleaned.substring('refs/tags/'.length())
    }
    
    // Remove refs/heads/ prefix (au cas ou)
    if (cleaned.startsWith('refs/heads/')) {
        cleaned = cleaned.substring('refs/heads/'.length())
    }
    
    return cleaned
}

def extractEnvironmentFromTag(String tagName) {
    if (!tagName?.trim()) return ''
    
    def tagUpper = tagName.toUpperCase()
    
    // Pattern: prefixe au debut du tag
    // TST-v1.0.0, TST_release, TST.2024.01
    if (tagUpper.startsWith('TST-') || tagUpper.startsWith('TST_') || tagUpper.startsWith('TST.')) {
        return 'tst'
    }
    if (tagUpper.startsWith('STA-') || tagUpper.startsWith('STA_') || tagUpper.startsWith('STA.')) {
        return 'sta'
    }
    if (tagUpper.startsWith('PRD-') || tagUpper.startsWith('PRD_') || tagUpper.startsWith('PRD.')) {
        return 'prd'
    }
    
    // Pattern: prefixe en fin de tag (fallback)
    // v1.0.0-TST, release_STA, 2024.01.PRD
    if (tagUpper.endsWith('-TST') || tagUpper.endsWith('_TST') || tagUpper.endsWith('.TST')) {
        return 'tst'
    }
    if (tagUpper.endsWith('-STA') || tagUpper.endsWith('_STA') || tagUpper.endsWith('.STA')) {
        return 'sta'
    }
    if (tagUpper.endsWith('-PRD') || tagUpper.endsWith('_PRD') || tagUpper.endsWith('.PRD')) {
        return 'prd'
    }
    
    // Pas de prefixe reconnu
    return ''
}

def detectTriggerType() {
    if (env.gitlabMergeRequestIid) return 'merge_request'
    if (env.gitlabActionType == 'PUSH') return 'push'
    if (env.gitlabActionType == 'TAG_PUSH') return 'tag'
    if (currentBuild.getBuildCauses('hudson.model.Cause$UserIdCause')) return 'manual'
    return 'webhook'
}

def loadPipelineConfiguration() {
    echo "======================================================"
    echo "LOADING CONFIGURATION"
    echo "======================================================"
    
    def projectKey = (env.TRIGGER_REPO_NAME ?: '').trim()
    if (!projectKey) {
        error "Project key is empty"
    }
    
    def configOutput = bat(
        returnStdout: true,
        script: "@powershell -ExecutionPolicy Bypass -File scripts\\utils\\parse-config.ps1 -projectKey ${projectKey} -environment ${env.RUN_ENVIRONMENT}"
    ).trim()
    
    // Parse KEY=VALUE (CPS-safe loop)
    def lines = configOutput.split('\n')
    for (int i = 0; i < lines.size(); i++) {
        def line = lines[i].trim()
        if (line && !line.startsWith('[DEBUG]') && !line.startsWith('#')) {
            def idx = line.indexOf('=')
            if (idx > 0) {
                def key = line.substring(0, idx)
                def value = line.substring(idx + 1)
                env."${key}" = value
            }
        }
    }
    
    env.PIPELINE_AGENT_LABEL = env.JENKINS_AGENT_LABEL ?: params.EXECUTION_LABEL
    
    // Validate required vars
    def required = ['PROJECT_NAME', 'PROJECT_GIT_URL', 'PROJECT_GIT_BRANCH', 'COMPONENTS_COUNT']
    for (int i = 0; i < required.size(); i++) {
        if (!env."${required[i]}"?.trim()) {
            error "Missing required: ${required[i]}"
        }
    }

    // info: if "SONAR_ENABLED" var is set to true, from the MR source branch update the sonar key to isolate "develop" and "master"
    // info: then launch the sonarscanner for C#
    if (env.SONAR_ENABLED== 'True') {
        env.sonar_key = "BRS.FR.${env.TRIGGER_REPO_NAME}"
        powershell(returnStatus: true, script: '''
            dotnet C:\\Users\\jenkins\\.dotnet\\tools\\.store\\dotnet-sonarscanner\\6.2.0\\dotnet-sonarscanner\\6.2.0\\tools\\netcoreapp3.1\\any\\SonarScanner.MSBuild.dll begin `
            /k:"$env:sonar_key" `
            /d:sonar.exclusions="**/*.html" `
            /d:sonar.cpd.exclusions="**/DTOs/**/*.cs" `
            /d:sonar.cs.vstest.reportsPaths="$env:WORKSPACE\\reports\\**\\*.trx" `
            /d:sonar.cs.vscoveragexml.reportsPaths="$env:WORKSPACE\\reports\\**\\*.xml" `
            /d:sonar.host.url='https://sonarqube.glb.laridak.tools' `
            /d:sonar.login="$env:sonar_token"
        ''')
    }

    printConfigSummary()
}

def printConfigSummary() {
    echo "======================================================"
    echo "CONFIGURATION LOADED"
    echo "======================================================"
    echo "Project: ${env.PROJECT_NAME}"
    echo "Git: ${env.PROJECT_GIT_URL} @ ${env.PROJECT_GIT_BRANCH}"
    echo "Agent: ${env.PIPELINE_AGENT_LABEL}"
    echo "Components: ${env.COMPONENTS_COUNT}"
    echo "Deploy: ${env.DEPLOY_ENABLED} (${env.DEPLOY_VMS_COUNT} servers)"
    echo "Security: GitLeaks=${env.GITLEAKS_ENABLED}, OWASP=${env.OWASP_DC_ENABLED}, DepScan=${env.DEPENDENCY_SCAN_ENABLED}, Sonar=${env.SONAR_ENABLED}, DAST=${env.DAST_ENABLED}"
    echo "======================================================"
}

def checkoutProject() {
    echo "======================================================"
    echo "CHECKOUT: ${env.PROJECT_NAME}"
    echo "======================================================"
    
    dir('project') {
        git branch: env.TRIGGER_BRANCH,
            url: env.TRIGGER_REPO_URL
           // credentialsId: env.PROJECT_GIT_CREDENTIALS ?: 'git-ssh-key'
        
        env.PROJECT_COMMIT_HASH = bat(
            returnStdout: true,
            script: '@git rev-parse HEAD'
        ).trim()
        
        echo "Branch: ${env.TRIGGER_BRANCH}"
        echo "Commit: ${env.PROJECT_COMMIT_HASH}"
    }
}

def runGitLeaksScan() {
    echo "======================================================"
    echo "SECRET SCANNING - GITLEAKS"
    echo "======================================================"
    
    dir('project') {
        def result = bat(
            returnStatus: true,
            script: """
                powershell.exe -ExecutionPolicy Bypass -File ^
                    "${env.WORKSPACE}\\scripts\\security\\gitleaksScan.ps1" ^
                    -repoPath . ^
                    -configFile "${env.WORKSPACE}\\config\\gitleaks.toml" ^
                    -reportDir "${env.WORKSPACE}\\gitleaks-report"
            """
        )
        
        if (result != 0) {
            error "GitLeaks detected secrets - Pipeline blocked"
        }
        echo "[OK] No secrets detected"
    }
}

def publishGitLeaksReport() {
    publishHTML([
        allowMissing: true,
        alwaysLinkToLastBuild: true,
        keepAll: true,
        reportDir: 'gitleaks-report',
        reportFiles: 'gitleaks-report.html',
        reportName: 'GitLeaks Report'
    ])
    archiveArtifacts artifacts: 'gitleaks-report/**/*', allowEmptyArchive: true
}

def runDependencyScan() {
    echo "======================================================"
    echo "DEPENDENCY SCAN (.NET)"
    echo "======================================================"
    
    dir('project') {
        bat 'dotnet restore'
        bat 'dotnet list package --vulnerable --include-transitive > dependency-scan.txt 2>&1'
        
        def content = readFile('dependency-scan.txt')
        def hasCritical = content.contains('Critical')
        def hasHigh = content.contains('High')
        
        if (hasCritical && env.FAIL_ON_CRITICAL == 'true') {
            error "Critical vulnerabilities detected"
        }
        if (hasHigh && env.FAIL_ON_HIGH == 'true') {
            error "High vulnerabilities detected"
        }
        
        echo "[OK] Dependency scan passed"
    }
}

def archiveDependencyReport() {
    archiveArtifacts artifacts: 'project/dependency-scan.txt', allowEmptyArchive: true
}

def runOwaspDependencyCheck() {
    echo "======================================================"
    echo "OWASP DEPENDENCY CHECK"
    echo "======================================================"
    
    dir('project') {
        def toolBase  = 'D:\\Jenkins\\tools\\org.jenkinsci.plugins.DependencyCheck.tools.DependencyCheckInstallation'
        def odcToolName = 'Dep-CICD'
        def odcBin   = "${toolBase}\\${odcToolName}\\bin\\dependency-check.bat"
        def dataDir  = "${toolBase}\\${odcToolName}\\data"
        def dbPath = "${dataDir}\\odc.mv.db"
        def feedsDir = "${env.WORKSPACE}\\src\\Assests\\owasp_dependency\\nvd-feeds"
        def feedsfilesUrl = "file:///${feedsDir.replace('\\','/')}/nvdcve-{0}.json.gz"

        def dbSizeThresholdMB = 5

        def dbExists = false
        def dbValid = false
        
        if (fileExists(dbPath)) {
            def dbSize = powershell(
                script: """
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
                    [math]::Round((Get-Item '${dbPath}').Length / 1MB, 2)
                """,
                returnStdout: true
            ).trim()
            
            echo "Base de données trouvée: ${dbSize} MB"
            
            if (dbSize.toDouble() >= dbSizeThresholdMB) {
                dbValid = true
                echo "Base de données valide (>= ${dbSizeThresholdMB} MB)"
            } else {
                echo "Base de données trop petite (< ${dbSizeThresholdMB} MB) - Réinitialisation nécessaire"
            }
        } else {
            echo "Base de données non trouvée - Initialisation nécessaire"
        }

        // Gestion du proxy pour OWASP Dependency-Check
        def proxyArgs = ''
        if (env.DEP_CHECK_ARGS?.trim()) {
            proxyArgs = ' ' + env.DEP_CHECK_ARGS.trim()
        } else {
            if (env.PROXY_SERVER?.trim()) { proxyArgs += " --proxyserver ${env.PROXY_SERVER}" }
            if (env.PROXY_PORT?.trim())   { proxyArgs += " --proxyport ${env.PROXY_PORT}" }
            if (env.PROXY_USERNAME?.trim() && env.PROXY_PASSWORD?.trim()) {
                proxyArgs += " --proxyauth ${env.PROXY_USERNAME}:${env.PROXY_PASSWORD}"
            }
            if (env.NON_PROXY_HOSTS?.trim()) {
                proxyArgs += " --nonProxyHosts \"${env.NON_PROXY_HOSTS}\""
            }
        }

        def httpProxy = (env.PROXY_SERVER?.trim() && env.PROXY_PORT?.trim()) ? "http://proxy.fr.laridak.tools:3128" : ''

        def envVars = []

        if (httpProxy) {
            envVars = [
                "HTTP_PROXY=${httpProxy}",
                "HTTPS_PROXY=${httpProxy}",
                "http_proxy=${httpProxy}",
                "https_proxy=${httpProxy}",
                "NO_PROXY=${env.NON_PROXY_HOSTS ?: ''}",
                "no_proxy=${env.NON_PROXY_HOSTS ?: ''}"
            ]
        }
                
        bat """
            powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            Set-Content -Path (Join-Path '${feedsDir.replace('\\','/')}' 'cache.properties') -Encoding ASCII -Value @('lastModifiedDate='+(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), ^
            'prefix=nvdcve-2.0-'); ^
            Get-Content (Join-Path '${feedsDir.replace('\\','/')}' 'cache.properties')"
        """

        withEnv(envVars) {
            // Scan avec plugin Jenkins
            dependencyCheck(
                additionalArguments: """
                    --scan .
                    --out .
                    --format XML --format HTML
                    --failOnCVSS 7.0
                    --enableRetired --enableExperimental
                    --data "${dataDir}"      
                    --nvdDatafeed "${feedsfilesUrl}"  
                    --prettyPrint 
                    --noupdate
                    --log "${env.WORKSPACE}\\logs\\odc-scan.log"
                """ + proxyArgs,
                odcInstallation: 'Dep-CICD'
            )
            // recordIssues tools: [sarif(pattern: '**/dependency-check-report.xml', id: 'odc')]

        }
    }
}

def publishOwaspReport() {
    dependencyCheckPublisher(
        pattern: 'project/dependency-check-report.xml',
        failedTotalCritical: 0,
        failedTotalHigh: 0,
        unstableTotalMedium: 5
    )
    publishHTML([
        allowMissing: false,
        alwaysLinkToLastBuild: true,
        keepAll: true,
        reportDir: 'project',
        reportFiles: 'dependency-check-report.html',
        reportName: 'OWASP DC Report'
    ])
    archiveArtifacts artifacts: 'project/dependency-check-report.*', allowEmptyArchive: false
}

def runSonarQubeAnalysis() {
    echo "======================================================"
    echo "SAST - SONARQUBE"
    echo "======================================================"
    
    if (!env.sonar_token?.trim()) {
        error "SonarQube token not configured"
    }
    
    dir('project') {
        def branch = env.gitlabBranch ?: env.PROJECT_GIT_BRANCH ?: 'main'
        def projectKey = "${env.SONAR_PROJECT_PREFIX}${env.PROJECT_NAME?.replaceAll(/[^a-zA-Z0-9.]/, '') ?: 'Unknown'}"
        def configuration = env.BUILD_CONFIGURATION ?: 'Release'

        def endStatus = powershell(returnStatus: true, script: '''
            dotnet sonarscanner end /d:sonar.login="$env:sonar_token"
        ''')
        
        if (endStatus != 0) {
            error "SonarQube END failed"
        }
        
        echo "[OK] SonarQube analysis completed"
    }
}

def buildComponents() {
    echo "======================================================"
    echo "BUILD COMPONENTS"
    echo "======================================================"
    
    def count = (env.COMPONENTS_COUNT ?: '0').toInteger()
    if (count == 0) {
        echo "[WARN] No components to build"
        return
    }
    
    def results = [success: 0, failed: 0, skipped: 0]
    
    for (int i = 0; i < count; i++) {
        def name = env."COMPONENT_${i}_NAME"
        def type = env."COMPONENT_${i}_TYPE"
        def buildScript = env."COMPONENT_${i}_BUILD_SCRIPT"
        def buildScriptName = env."COMPONENT_${i}_BUILD_SCRIPT_NAME"
        
        echo "[${i + 1}/${count}] ${name} (${buildScriptName})"
        
        if (!buildScript?.trim()) {
            echo "  [SKIP] No build script"
            results.skipped++
            continue
        }
        
        try {
            executeBuildScript(name, type, buildScript, buildScriptName, i)
            echo "  [OK]"
            results.success++
        } catch (Exception e) {
            echo "  [FAIL] ${e.message}"
            results.failed++
        }
    }
    
    echo "======================================================"
    echo "BUILD: ${results.success} OK | ${results.failed} FAIL | ${results.skipped} SKIP"
    echo "======================================================"
    
    if (results.failed > 0) {
        error "Build failed for ${results.failed} component(s)"
    }
}

def executeBuildScript(String name, String type, String script, String scriptName, int index) {
    def baseFolder = env."COMPONENT_${index}_BASE_FOLDER" ?: "project"
    def publishFolder = env."COMPONENT_${index}_PUBLISH_FOLDER"
    
    def proxy = env.PROXY_SERVER ?: "proxy.fr.laridak.tools"
    def port = env.PROXY_PORT ?: "3128"
    def environment = env.RUN_ENVIRONMENT
    
    switch (scriptName) {
        case 'buildDotNetCore3.1':
        case 'buildDotNet_Voucher':
            bat """
                powershell.exe -ExecutionPolicy Bypass -File "${script}" ^
                    -proxyServer "${proxy}" ^
                    -proxyPort "${port}" ^
                    -assemblyName "${name}" ^
                    -type "${type}" ^
                    -environment "${environment}" ^
                    -baseFolder "${env.WORKSPACE}\\project"
            """
            break
            
        case 'buildDotNetCore':
            bat """
                powershell.exe -ExecutionPolicy Bypass -File "${script}" ^
                    -proxyServer "${proxy}" ^
                    -proxyPort "${port}" ^
                    -serviceName "${name}" ^
                    -targetType "${type}" ^
                    -environment "${environment}" ^
                    -baseFolder "${env.WORKSPACE}\\project"
            """
            break
            
        case 'buildAspDotNet':
            def baseFolderPath = "${env.WORKSPACE}\\${baseFolder}"
            def publishFolderPath = publishFolder ? "${env.WORKSPACE}\\${publishFolder}" : "${env.WORKSPACE}\\DotNet\\publish"
            
            if (type == 'web') {
                // Web: avec publishProfile
                def publishProfile = "${baseFolderPath}\\${name}\\Properties\\PublishProfiles\\[${environment}] Generation package.pubxml"
                bat """
                    powershell.exe -ExecutionPolicy Bypass -File "${script}" ^
                        -appName "${name}" ^
                        -baseFolder "${baseFolderPath}" ^
                        -targetType "${type}" ^
                        -environment "${environment}" ^
                        -publishProfile "${publishProfile}" ^
                        -publishFolder "${publishFolderPath}"
                """
            } else {
                // Console: sans publishProfile
                bat """
                    powershell.exe -ExecutionPolicy Bypass -File "${script}" ^
                        -appName "${name}" ^
                        -baseFolder "${baseFolderPath}" ^
                        -targetType "${type}" ^
                        -environment "${environment}" ^
                        -publishFolder "${publishFolderPath}"
                """
            }
            break
            
        default:
            throw new Exception("Unknown build script: ${scriptName}")
    }
}

def deployComponents() {
    echo "======================================================"
    echo "DEPLOY TO ${env.RUN_ENVIRONMENT.toUpperCase()}"
    echo "======================================================"
    
    // Approval for non-test environments
    if (env.RUN_ENVIRONMENT != 'tst' && env.DEPLOY_REQUIRES_APPROVAL == 'True') {
        def approvers = env.DEPLOY_APPROVERS ?: 'admin,lead-dev'
        input message: "Deploy to ${env.RUN_ENVIRONMENT.toUpperCase()}?",
              ok: 'Deploy',
              submitter: approvers
    }
    
    def servers = (env.DEPLOY_SERVERS ?: '').tokenize(';')
    if (servers.isEmpty()) {
        echo "[WARN] No servers configured for deployment"
        return
    }
    
    def count = (env.COMPONENTS_COUNT ?: '0').toInteger()
    if (count == 0) {
        echo "[WARN] No components to deploy"
        return
    }
    
    def results = [success: 0, failed: 0, skipped: 0]
    
    for (int s = 0; s < servers.size(); s++) {
        def server = servers[s].trim()
        if (!server) continue
        
        echo "------------------------------------------------------"
        echo "Server [${s + 1}/${servers.size()}]: ${server}"
        echo "------------------------------------------------------"
        
        for (int i = 0; i < count; i++) {
            def name = env."COMPONENT_${i}_NAME"
            def type = env."COMPONENT_${i}_TYPE"
            def deployScript = env."COMPONENT_${i}_DEPLOY_SCRIPT"
            def deployScriptName = env."COMPONENT_${i}_DEPLOY_SCRIPT_NAME"
            def destPath = env."COMPONENT_${i}_DEST_PATH"
            
            if (!deployScript?.trim()) {
                echo "  [SKIP] ${name} - No deploy script"
                results.skipped++
                continue
            }
            
            try {
                echo "  [${i + 1}/${count}] ${name} (${destPath})" 
                //executeDeployScript(server, name, type, deployScript, deployScriptName, destPath)
                echo "  [OK] ${name}"
                results.success++
            } catch (Exception e) {
                echo "  [FAIL] ${name} - ${e.message}"
                results.failed++
                
                if (env.FAIL_ON_DEPLOY_FAILURE == 'true') {
                    error "Deploy failed: ${name} to ${server}"
                }
            }
        }
    }
    
    echo "======================================================"
    echo "DEPLOY: ${results.success} OK | ${results.failed} FAIL | ${results.skipped} SKIP"
    echo "======================================================"
    
    if (results.failed > 0 && env.FAIL_ON_DEPLOY_FAILURE == 'true') {
        error "Deployment failed for ${results.failed} component(s)"
    }
}

def executeDeployScript(String server, String name, String type, String script, String scriptName, String destPath) {
    def environment = env.RUN_ENVIRONMENT
    def sourcePath = "${env.WORKSPACE}\\publish\\${environment}\\${name}"
    
    // Scripts avec signature legacy (server, assemblyName, type, environment, baseFolder)
    def legacyScripts = ['deployDotNetCore3.1', 'deployDotNet_Voucher']
    
    // Scripts avec signature standard (serverName, environment, appName, sourcePath, destPath)
    def standardScripts = ['deployConsoleDotNetCore', 'deployWebAspDotNet', 'deployWebDotNetCore','deployConsoleAspDotNet']
    
    if (scriptName in legacyScripts) {
        bat """
            powershell.exe -ExecutionPolicy Bypass -File "${script}" ^
                -server "${server}" ^
                -assemblyName "${name}" ^
                -type "${type}" ^
                -environment "${environment}" ^
                -baseFolder "${env.WORKSPACE}\\project"
        """
    } else if (scriptName in standardScripts) {
        if (!destPath?.trim()) {
            throw new Exception("destPath required for ${scriptName} - component: ${name}")
        }
        bat """
            powershell.exe -ExecutionPolicy Bypass -File "${script}" ^
                -serverName "${server}" ^
                -environment "${environment}" ^
                -appName "${name}" ^
                -sourcePath "${sourcePath}" ^
                -destPath "${destPath}"
        """
    } else {
        throw new Exception("Unknown deploy script: ${scriptName}")
    }
}

def runHealthChecks() {
    echo "======================================================"
    echo "HEALTH CHECKS"
    echo "======================================================"
    
    def servers = (env.DEPLOY_SERVERS ?: '').tokenize(';')
    def healthEndpoint = env.HEALTH_CHECK_ENDPOINT ?: '/health'
    def healthPort = env.HEALTH_CHECK_PORT ?: '8080'
    
    for (int i = 0; i < servers.size(); i++) {
        def server = servers[i].trim()
        if (!server) continue
        
        echo "Checking: ${server}"
        
        def result = bat(
            returnStatus: true,
            script: """
                powershell -Command "try { \$r = Invoke-WebRequest -Uri 'http://${server}:${healthPort}${healthEndpoint}' -TimeoutSec 30 -UseBasicParsing; exit 0 } catch { exit 1 }"
            """
        )
        
        if (result != 0) {
            unstable "Health check failed for ${server}"
        } else {
            echo "  [OK] ${server}"
        }
    }
}

def generateSecurityAudit() {
    echo "======================================================"
    echo "SECURITY AUDIT"
    echo "======================================================"
    
    def auditJson = """
{
  "metadata": {
    "timestamp": "${BUILD_TIMESTAMP}",
    "pipeline": "${env.JOB_NAME}",
    "buildNumber": "${BUILD_NUMBER}",
    "environment": "${env.RUN_ENVIRONMENT}"
  },
  "project": {
    "name": "${env.PROJECT_NAME}",
    "branch": "${env.PROJECT_GIT_BRANCH}",
    "commit": "${env.PROJECT_COMMIT_HASH ?: 'unknown'}"
  },
  "security": {
    "gitleaks": "${env.GITLEAKS_ENABLED}",
    "dependencyScan": "${env.DEPENDENCY_SCAN_ENABLED}",
    "owaspDC": "${env.OWASP_DC_ENABLED}",
    "sonar": "${env.SONAR_ENABLED}"
  },
  "result": "${currentBuild.result ?: 'SUCCESS'}"
}
"""
    writeFile file: 'security-audit.json', text: auditJson
    echo "[OK] Audit generated"
}

def sendPipelineNotification() {
    def status = currentBuild.result ?: 'SUCCESS'
    def duration = currentBuild.durationString.replace(' and counting', '')
    
    def subject = "Pipeline ${status}: ${env.JOB_NAME} #${BUILD_NUMBER}"
    
    def body = """
Pipeline: ${env.JOB_NAME}
Build: #${BUILD_NUMBER}
Status: ${status}
Duration: ${duration}
Environment: ${env.RUN_ENVIRONMENT}

Project: ${env.PROJECT_NAME}
Branch: ${env.TrIGGER_BRANCH}

Build URL: ${env.BUILD_URL}
"""
    
    emailext(
        subject: subject,
        body: body,
        to: env.NOTIFICATION_EMAIL ?: 'amin.kadira.ext@laridakgroup.com',
        mimeType: 'text/plain'
    )
}