package com.aliothmoon.maafw.third;

import android.os.Process;
import android.util.Log;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;

/**
 * 同时写入 Android logger（logcat 可见）、进程标准输出/错误（终端直接可见）与可选文件
 * （导出日志包可见）的日志门面。
 *
 * 特权进程（app_process 拉起，无 Koin/Timber）内的专用日志通道：app 侧按仓库惯例走 Timber，
 * 特权进程里只能用它。每条日志双路输出：Log.v/d/i/w/e 进 logcat（TAG 固定 [TAG]），
 * 同时带 [PREFIX] 前缀打到 stdout（v/i/d）或 stderr（w/e）。
 *
 * {@link #initFileSink(File)} 追加第三路：特权进程经 Shizuku/root 拉起，logcat 用户拿不到，
 * 标准流也无人接——不落盘的话「搬屏盯防为何没生效」这类问题在用户导出的日志包里永远看不到
 * （issue #8 复测排查的直接障碍）。sink 写到 App 的 debug 诊断目录，随 launcher_logs zip
 * 一起导出；init 前为 no-op，任何写盘失败都吞掉，绝不影响主流程。
 *
 * Log both to Android logger (so that logs are visible in "adb logcat"), standard output/error (so that they are visible in the terminal
 * directly), and an optional file (visible in the exported log bundle).
 */
public final class Ln {

    private static final String TAG = "MaaFw";
    private static final String PREFIX = "[MC] ";

    private static final PrintStream CONSOLE_OUT = new PrintStream(new FileOutputStream(FileDescriptor.out));
    private static final PrintStream CONSOLE_ERR = new PrintStream(new FileOutputStream(FileDescriptor.err));

    public enum Level {
        VERBOSE, DEBUG, INFO, WARN, ERROR
    }

    private static Level threshold = Level.DEBUG;

    /** 文件 sink：initFileSink 前为 null；单锁串行化追加，binder 线程与各协程都会写 */
    private static final Object SINK_LOCK = new Object();

    private static volatile File sinkFile;

    /** 文件 sink 的滚动上限；超限滚动为 .1（只留一代）/ The sink rotation cap; rotated to .1 (one generation kept) */
    private static final long SINK_MAX_BYTES = 512 * 1024L;

    private static final DateTimeFormatter TIME_FMT = DateTimeFormatter.ofPattern("MM-dd HH:mm:ss.SSS");

    private Ln() {
        // not instantiable
    }

    /**
     * 启用文件 sink：此后每条日志（含历史格式）按行追加到 {@code {dir}/remote_process_debug.log}，
     * 带时间戳与级别，超限滚动为 .1。
     *
     * 幂等：重复调用换目标文件（同一目录则等效刷新）。任何参数异常按无 sink 处理。
     *
     * Enables the file sink: every entry afterwards is appended to
     * {@code {dir}/remote_process_debug.log} with a timestamp and level, rotated to .1
     * past the cap.
     *
     * @param dir 目标目录，null 表示不启用 / target directory, null means no sink
     */
    public static void initFileSink(File dir) {
        if (dir == null) return;
        synchronized (SINK_LOCK) {
            try {
                dir.mkdirs();
            } catch (Throwable ignored) {
                // 目录建不出来就退化成「写失败被吞」，不影响主流程
            }
            sinkFile = new File(dir, "remote_process_debug.log");
            // sink 自身的启用/换向记录进文件，方便对齐会话边界
            appendSinkLocked(Level.INFO, "file sink enabled (pid=" + Process.myPid() + ")", null);
        }
    }

    public static void disableSystemStreams() {
        PrintStream nullStream = new PrintStream(new NullOutputStream());
        System.setOut(nullStream);
        System.setErr(nullStream);
    }

    /**
     * Initialize the log level.
     * <p>
     * Must be called before starting any new thread.
     *
     * @param level the log level
     */
    public static void initLogLevel(Level level) {
        threshold = level;
    }

    public static boolean isEnabled(Level level) {
        return level.ordinal() >= threshold.ordinal();
    }

    public static void v(String message) {
        if (isEnabled(Level.VERBOSE)) {
            Log.v(TAG, message);
            CONSOLE_OUT.print(PREFIX + "VERBOSE: " + message + '\n');
            appendSink(Level.VERBOSE, message, null);
        }
    }

    public static void d(String message) {
        if (isEnabled(Level.DEBUG)) {
            Log.d(TAG, message);
            CONSOLE_OUT.print(PREFIX + "DEBUG: " + message + '\n');
            appendSink(Level.DEBUG, message, null);
        }
    }

    public static void i(String message) {
        if (isEnabled(Level.INFO)) {
            Log.i(TAG, message);
            CONSOLE_OUT.print(PREFIX + "INFO: " + message + '\n');
            appendSink(Level.INFO, message, null);
        }
    }

    public static void w(String message, Throwable throwable) {
        if (isEnabled(Level.WARN)) {
            Log.w(TAG, message, throwable);
            CONSOLE_ERR.print(PREFIX + "WARN: " + message + '\n');
            if (throwable != null) {
                throwable.printStackTrace(CONSOLE_ERR);
            }
            appendSink(Level.WARN, message, throwable);
        }
    }

    public static void w(String message) {
        w(message, null);
    }

    public static void e(String message, Throwable throwable) {
        if (isEnabled(Level.ERROR)) {
            Log.e(TAG, message, throwable);
            CONSOLE_ERR.print(PREFIX + "ERROR: " + message + '\n');
            if (throwable != null) {
                throwable.printStackTrace(CONSOLE_ERR);
            }
            appendSink(Level.ERROR, message, throwable);
        }
    }

    public static void e(String message) {
        e(message, null);
    }

    /**
     * 追加一条到文件 sink（内部持锁）。失败只吞掉——诊断通道永远不能反噬主流程。
     *
     * Appends one entry to the file sink (takes the lock). Failures are swallowed —
     * a diagnostic channel must never bite the main flow.
     */
    private static void appendSink(Level level, String message, Throwable throwable) {
        if (sinkFile == null) return;
        synchronized (SINK_LOCK) {
            appendSinkLocked(level, message, throwable);
        }
    }

    /** 追加一条到文件 sink；须持 [SINK_LOCK]。/ Appends one entry; call with {@link #SINK_LOCK} held. */
    private static void appendSinkLocked(Level level, String message, Throwable throwable) {
        File file = sinkFile;
        if (file == null) return;
        try {
            if (file.exists() && file.length() > SINK_MAX_BYTES) {
                File bak = new File(file.getParentFile(), file.getName() + ".1");
                if (bak.exists()) {
                    // 只留一代；删不掉就直接覆盖写，仍不抛
                    bak.delete();
                }
                file.renameTo(bak);
            }
            String time = Instant.now().atZone(ZoneId.systemDefault()).format(TIME_FMT);
            appendText(file, time + "  " + level + "  " + message + "\n");
            if (throwable != null) {
                // 栈要完整现场，直接落 printStackTrace 的输出（logcat 侧同样如此）
                StringWriter sw = new StringWriter();
                throwable.printStackTrace(new PrintWriter(sw));
                appendText(file, sw + "\n");
            }
        } catch (Throwable ignored) {
            // 诊断通道写失败一律吞掉，绝不反噬主流程
        }
    }

    private static void appendText(File file, String text) throws java.io.IOException {
        FileWriter writer = new FileWriter(file, true);
        try {
            writer.write(text);
        } finally {
            writer.close();
        }
    }

    static class NullOutputStream extends OutputStream {
        @Override
        public void write(byte[] b) {
            // ignore
        }

        @Override
        public void write(byte[] b, int off, int len) {
            // ignore
        }

        @Override
        public void write(int b) {
            // ignore
        }
    }
}
