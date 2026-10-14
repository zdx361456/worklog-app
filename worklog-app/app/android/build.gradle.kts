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
// ---------------------------------------------------------------------------
// [compileSdk-fix · 2026-10-13 · 位置订正 2026-10-14] 统一抬高「所有 Android
// 子工程（含插件模块）」的 compileSdk 到 36。
//
// 为什么需要：
//   部分插件在自己的 android/build.gradle 里把 compileSdk 写死成 34
//   （实测 file_picker 8.3.7、share_plus 10.1.4），而 file_picker 依赖的
//   flutter_plugin_android_lifecycle 要求消费者 compileSdk >= 36，
//   于是 :file_picker:checkReleaseAarMetadata 直接失败 → release 构建整体失败，
//   桌面上留下的仍是上一次成功构建的旧包（极易被误当成"新包"装上）。
//   本机已安装 android-36 / android-36.1，无需额外下载。
//
// 为什么用反射：
//   AGP 只在 settings.gradle.kts 的 plugins 块里声明（apply false），
//   根工程脚本没有 AGP 的编译期类路径，直接引用 com.android.build.gradle.*
//   会导致脚本编译失败，故按方法名动态调用。
//
// ★ 为什么必须写在这个位置（不能挪到文件末尾）：
//   下面那段 subprojects { evaluationDependsOn(":app") } 会**提前**把 :app 求值掉，
//   之后注册的 afterEvaluate 对 :app 永远拿不到（会抛 "already evaluated"）。
//   实测（2026-10-13 gradle_config_probe.log）：块放在末尾时 :app 每构建都走
//   「已求值 → 立即应用（可能过晚）」这条退路 —— 是常态，不是极端情况。
//   把它排到 evaluationDependsOn 之前，所有子工程才能走正常的 afterEvaluate 通道。
// ---------------------------------------------------------------------------
fun raiseCompileSdk(project: Project, version: Int) {
    val androidExtension = project.extensions.findByName("android") ?: return

    val candidates = listOf("compileSdkVersion", "setCompileSdkVersion", "setCompileSdk")
    var setter: java.lang.reflect.Method? = null
    for (name in candidates) {
        setter = androidExtension.javaClass.methods.firstOrNull {
            it.name == name && it.parameterCount == 1 &&
                (it.parameterTypes[0] == Int::class.javaPrimitiveType ||
                    it.parameterTypes[0] == java.lang.Integer::class.java)
        }
        if (setter != null) break
    }

    val ok = setter != null && runCatching {
        setter.invoke(androidExtension, version)
        true
    }.getOrDefault(false)

    if (ok) {
        project.logger.lifecycle("[compileSdk-fix] ${project.path} -> compileSdk $version (via ${setter!!.name})")
    } else {
        project.logger.warn(
            "[compileSdk-fix] 未能为 ${project.path} 设置 compileSdk=$version（AGP API 可能已变化）"
        )
    }
}

subprojects {
    val target = this
    if (target.state.executed) {
        // 兜底：理论上不该走到这里（本块已排在 evaluationDependsOn 之前）。
        // 若真走到，说明该子工程在注册时点已被求值，afterEvaluate 会抛异常，
        // 只能立即应用 —— 对 AGP 而言可能已过晚，故用 warn 而非 lifecycle。
        target.logger.warn("[compileSdk-fix] ${target.path} 注册时已求值，立即应用（可能过晚）")
        raiseCompileSdk(target, 36)
    } else {
        target.afterEvaluate { raiseCompileSdk(target, 36) }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
