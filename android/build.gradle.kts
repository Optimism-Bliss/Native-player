allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Android lint crashes while analysing webview_all_android's generated Kotlin
// ("Unexpected failure during lint analysis ... this is a bug in lint"), which
// fails every release build. Skip the release-time lint pass for plugins.
subprojects {
    if (name != "app") {
        tasks.configureEach {
            if (name.startsWith("lintVital")) enabled = false
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
