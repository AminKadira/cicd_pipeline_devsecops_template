// vars/sendPipelineEmail.groovy
def call(Map config = [:]) {
    script {
        // Calcul status et durée
        def duration = currentBuild.durationString.replace(' and counting', '')
        def status = currentBuild.result ?: 'SUCCESS'
        
        // Configuration status
        def statusConfig = [
            'SUCCESS': [color: '#36a64f', emoji: '✅', label: 'SUCCESS'],
            'FAILURE': [color: '#dc3545', emoji: '❌', label: 'FAILURE'],
            'UNSTABLE': [color: '#ffc107', emoji: '⚠️', label: 'UNSTABLE'],
            'ABORTED': [color: '#6c757d', emoji: '🛑', label: 'ABORTED']
        ]
        
        def statusInfo = statusConfig[status] ?: statusConfig['FAILURE']
        
        // Helper function pour status stage
        def getStageStatus = { skipParam ->
            return skipParam ? [status: 'SKIPPED', cssClass: 'skipped'] : [status: 'COMPLETED', cssClass: 'success']
        }
        
        def secValidation = getStageStatus(params.SKIP_SECURITY_VALIDATION)
        def depScan = getStageStatus(params.SKIP_DEPENDENCY_SCAN)
        def sastAnalysis = getStageStatus(params.SKIP_SAST_ANALYSIS)
        def secTesting = getStageStatus(params.SKIP_SECURE_TESTING)
        def buildSigning = getStageStatus(params.SKIP_BUILD_SIGNING)
        
        // Chargement template
        def templatePath = config.templatePath ?: 'templates/html/email-pipeline-report.html'
        
        if (!fileExists(templatePath)) {
            error "Email template not found: ${templatePath}"
        }
        
        def emailTemplate = readFile(templatePath)
        
        // Remplacement variables
        def emailBody = emailTemplate
            .replace('{{STATUS_COLOR}}', statusInfo.color)
            .replace('{{STATUS_EMOJI}}', statusInfo.emoji)
            .replace('{{STATUS_LABEL}}', statusInfo.label)
            .replace('{{PROJECT_NAME}}', env.PROJECT_NAME ?: env.JOB_NAME)
            .replace('{{BUILD_NUMBER}}', env.BUILD_NUMBER)
            .replace('{{DURATION}}', duration)
            .replace('{{ENVIRONMENT}}', params.ENVIRONMENT ?: 'test')
            .replace('{{COMMIT_HASH}}', env.BUILD_HASH?.substring(0, 8) ?: 'N/A')
            .replace('{{BRANCH}}', env.REPO_BRANCH ?: env.GIT_BRANCH ?: 'N/A')
            .replace('{{BUILD_URL}}', env.BUILD_URL)
            .replace('{{TIMESTAMP}}', new Date().format('yyyy-MM-dd HH:mm:ss'))
            .replace('{{SECURITY_VALIDATION_CLASS}}', secValidation.cssClass)
            .replace('{{SECURITY_VALIDATION_STATUS}}', secValidation.status)
            .replace('{{DEPENDENCY_SCAN_CLASS}}', depScan.cssClass)
            .replace('{{DEPENDENCY_SCAN_STATUS}}', depScan.status)
            .replace('{{SAST_ANALYSIS_CLASS}}', sastAnalysis.cssClass)
            .replace('{{SAST_ANALYSIS_STATUS}}', sastAnalysis.status)
            .replace('{{SECURE_TESTING_CLASS}}', secTesting.cssClass)
            .replace('{{SECURE_TESTING_STATUS}}', secTesting.status)
            .replace('{{BUILD_SIGNING_CLASS}}', buildSigning.cssClass)
            .replace('{{BUILD_SIGNING_STATUS}}', buildSigning.status)
        
        // Destinataires
        def recipients = config.to ?: (env.BUILD_USER_EMAIL ?: 'amin.kadira.ext@laridakgroup.com')
        
        // Envoi email
        emailext (
            subject: "${statusInfo.emoji} Pipeline ${statusInfo.label}: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
            body: emailBody,
            mimeType: 'text/html',
            to: recipients,
            recipientProviders: [[$class: 'DevelopersRecipientProvider']]
        )
        
        echo "Email sent successfully to: ${recipients}"
    }
}