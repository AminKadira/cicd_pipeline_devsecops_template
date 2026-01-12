// vars/buildComponents.groovy

def call(Map config = [:]) {
    def count = (env.COMPONENTS_COUNT ?: '0').toInteger()
    
    if (count == 0) {
        echo "[WARN] No components to build"
        return [success: 0, failed: 0, skipped: 0]
    }
    
    echo "======================================================"
    echo "BUILDING ${count} COMPONENT(S)"
    echo "======================================================"
    
    def results = [success: 0, failed: 0, skipped: 0]
    
    for (int i = 0; i < count; i++) {
        def name = env."COMPONENT_${i}_NAME"
        def type = env."COMPONENT_${i}_TYPE"
        def category = env."COMPONENT_${i}_CATEGORY"
        def buildScript = env."COMPONENT_${i}_BUILD_SCRIPT"
        def buildScriptName = env."COMPONENT_${i}_BUILD_SCRIPT_NAME"
        
        echo "[${i + 1}/${count}] ${name} (${category}/${type})"
        
        if (!buildScript?.trim()) {
            echo "  [SKIP] No build script"
            results.skipped++
            continue
        }
        
        try {
            if (buildScriptName == 'buildDotNetCore3.1') {
                bat """
                    powershell.exe -ExecutionPolicy Bypass -File "${buildScript}" ^
                        -proxyServer "${env.PROXY_SERVER ?: 'proxy.fr.laridak.tools'}" ^
                        -proxyPort "${env.PROXY_PORT ?: '3128'}" ^
                        -assemblyName "${name}" ^
                        -type "${type}" ^
                        -environment "${config.environment ?: 'tst'}" ^
                        -baseFolder "${env.WORKSPACE}\\project"
                """
                echo "  [OK]"
                results.success++
            } else {
                echo "  [SKIP] Unknown script: ${buildScriptName}"
                results.skipped++
            }
        } catch (Exception e) {
            echo "  [FAIL] ${e.message}"
            results.failed++
        }
    }
    
    echo "======================================================"
    echo "BUILD: ${results.success} OK | ${results.failed} FAIL | ${results.skipped} SKIP"
    echo "======================================================"
    
    return results
}