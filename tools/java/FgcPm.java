import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.AdaptiveIconDrawable;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.util.Base64;

import java.io.ByteArrayOutputStream;
import java.util.List;

/**
 * FgcPm — FGC PackageManager helper, run on-device via:
 *   app_process -Djava.class.path=/data/adb/fgc/bin/fgc-pm.dex /system/bin FgcPm <list|icon|icons|ping> [pkg...]
 *
 * Uses real PackageManager (labels + icons on every ROM, no dumpsys roulette).
 * All output is single-line tab-separated; icons as base64 PNG (144px).
 * `list`  = pkg<TAB>label<TAB>user|system<TAB>versionCode (versionCode feeds the
 *           icon cache key so updates retire a stale bitmap).
 * `icon`  = one package  -> base64 PNG.
 * `icons` = many packages -> pkg<TAB>base64 PNG per line. JVM startup dominates
 *           icon cost (~0.5-1s), so a list of uncached icons is rendered in ONE
 *           process instead of one process per row. Individual failures are
 *           skipped, never fatal.
 * Any failure -> non-zero exit, CLI falls back to pm/dumpsys automatically.
 */
public class FgcPm {
    private static final int ICON_PX = 144;

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Throwable t) {
            // Never die silently: app_process + RuntimeInit turn uncaught
            // exceptions into confusing aborts. Print and exit non-zero so
            // the shell CLI can fall back gracefully.
            System.err.println("FgcPm FAILED: " + t);
            t.printStackTrace();
            System.exit(1);
        }
    }

    private static void run(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("usage: FgcPm list|icon <pkg>|icons <pkg...>|ping");
            System.exit(2);
        }
        PackageManager pm = systemPackageManager();
        if ("ping".equals(args[0])) {
            System.out.println("pong");
        } else if ("list".equals(args[0]) && args.length == 1) {
            // ONE binder call: getInstalledPackages carries both the
            // ApplicationInfo and the versionCode. Calling getPackageInfo per
            // app instead cost ~4s for 405 packages on a real device.
            List<PackageInfo> pkgs = pm.getInstalledPackages(0);
            for (PackageInfo pi : pkgs) {
                ApplicationInfo ai = pi.applicationInfo;
                if (ai == null) continue;
                String label = safe(String.valueOf(ai.loadLabel(pm)));
                boolean sys = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0
                        && (ai.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0;
                // 4th column = versionCode. The CLI feeds it to `icon <pkg> <ver>`
                // as the icon-cache key, so a cached bitmap is retired exactly
                // when the app is updated. versionCode (not versionName) is used
                // because some apps ship a new build under the same name.
                System.out.println(ai.packageName + "\t" + label + "\t" + (sys ? "system" : "user") + "\t" + versionCodeOf(pi));
            }
        } else if ("icon".equals(args[0]) && args.length == 2 && validPkg(args[1])) {
            Bitmap bmp = renderIcon(pm, args[1]);
            if (bmp == null) System.exit(1);
            System.out.println(pngBase64(bmp));
        } else if ("icons".equals(args[0])) {
            // Batch render: the CLI pays ONE JVM start for a whole chunk of
            // uncached icons. A package whose icon cannot be rendered is
            // skipped (the caller keeps its letter avatar) instead of killing
            // the batch; only a total miss exits non-zero.
            int done = 0;
            for (int i = 1; i < args.length; i++) {
                String p = args[i];
                if (!validPkg(p)) continue;
                // Per-package guard: ONE bad icon must never kill the rest of
                // the batch. Without it an escaping throwable aborted the loop,
                // so every later package in that chunk silently kept its letter
                // avatar ("icons sometimes show as letters").
                try {
                    Bitmap bmp = renderIcon(pm, p);
                    if (bmp == null) continue;
                    System.out.println(p + "\t" + pngBase64(bmp));
                    bmp.recycle();
                    done++;
                } catch (Throwable t) {
                    System.err.println("icon failed: " + p + " " + shortErr(t));
                }
            }
            if (done == 0) System.exit(1);
        } else {
            System.err.println("bad args");
            System.exit(2);
        }
    }

    private static PackageManager systemPackageManager() throws Exception {
        // app_process has NO ActivityThread (currentActivityThread() == null),
        // so we must create one. ROMs differ: try every known path and
        // report ALL failures (silent aborts help nobody).
        // FIRST: ActivityThread creates Handlers, which require a prepared
        // Looper on this thread — without it everything dies with
        // "Can't create handler inside thread that has not called Looper.prepare()".
        try {
            Class.forName("android.os.Looper").getMethod("prepareMainLooper").invoke(null);
        } catch (Throwable t) {
            try {
                Class.forName("android.os.Looper").getMethod("prepare").invoke(null);
            } catch (Throwable t2) {
                // already prepared (or unavailable) — proceed anyway
            }
        }
        Class<?> at = Class.forName("android.app.ActivityThread");
        StringBuilder why = new StringBuilder();
        // Lightweight manual attach first (less vendor native surface than
        // systemMain, whose MIUI hooks abort non-deterministically).
        Object thread = tryManualAttach(at, why);
        if (thread == null) {
            try {
                thread = at.getMethod("systemMain").invoke(null);
            } catch (Throwable t) {
                why.append("systemMain: ").append(shortErr(t)).append("; ");
                thread = null;
            }
        }
        if (thread == null) {
            try {
                thread = at.getMethod("currentActivityThread").invoke(null);
                if (thread == null) why.append("currentActivityThread: null; ");
            } catch (Throwable t) {
                why.append("currentActivityThread: ").append(shortErr(t)).append("; ");
                thread = null;
            }
        }
        if (thread == null) throw new RuntimeException("no ActivityThread available [" + why + "]");
        Context ctx = null;
        String[] getters = {"getSystemContext", "getApplication"};
        for (int i = 0; i < getters.length && ctx == null; i++) {
            try {
                Object o = at.getMethod(getters[i]).invoke(thread);
                if (o instanceof Context) ctx = (Context) o;
            } catch (Throwable t) {
                ctx = null;
            }
        }
        if (ctx == null) {
            try {
                Object app = at.getMethod("currentApplication").invoke(null);
                if (app instanceof Context) ctx = (Context) app;
            } catch (Throwable t) {
                ctx = null;
            }
        }
        if (ctx == null) throw new RuntimeException("no Context from ActivityThread");
        return ctx.getPackageManager();
    }

    private static Object tryManualAttach(Class<?> at, StringBuilder why) {
        // new ActivityThread() + attach(...). Signature varies by API, so try
        // each shape. system=false keeps it lighter than systemMain().
        try {
            java.lang.reflect.Constructor<?> ctor = at.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object t2 = ctor.newInstance();
            String[] shapes = {"ZI", "Z"};
            Object[][] args = {{Boolean.FALSE, Integer.valueOf(0)}, {Boolean.FALSE}};
            for (int i = 0; i < shapes.length; i++) {
                try {
                    Class<?>[] pt = new Class<?>[shapes[i].length()];
                    for (int j = 0; j < pt.length; j++) {
                        pt[j] = shapes[i].charAt(j) == 'Z' ? Boolean.TYPE : Integer.TYPE;
                    }
                    java.lang.reflect.Method m = at.getDeclaredMethod("attach", pt);
                    m.setAccessible(true);
                    m.invoke(t2, args[i]);
                    // Verify the context is real before trusting this path;
                    // otherwise fall through to systemMain.
                    Object sc = null;
                    try {
                        sc = at.getMethod("getSystemContext").invoke(t2);
                    } catch (Throwable tsc) {
                        sc = null;
                    }
                    if (sc != null) return t2;
                    why.append("attach").append(shapes[i]).append(": no system context; ");
                } catch (Throwable t) {
                    why.append("attach").append(shapes[i]).append(": ").append(shortErr(t)).append("; ");
                }
            }
        } catch (Throwable t) {
            why.append("new ActivityThread: ").append(shortErr(t)).append("; ");
        }
        return null;
    }

    private static String shortErr(Throwable t) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 3 && t != null; i++) {
            String m = t.getMessage();
            String s = t.getClass().getName();
            int dot = s.lastIndexOf('.');
            if (dot >= 0) s = s.substring(dot + 1);
            if (i > 0) sb.append(" caused by ");
            sb.append(s).append(m == null ? "" : ": " + (m.length() > 150 ? m.substring(0, 150) : m));
            t = t.getCause();
        }
        return sb.toString();
    }

    private static boolean validPkg(String p) {
        if (p == null || p.length() == 0 || p.length() > 256) return false;
        for (int i = 0; i < p.length(); i++) {
            char c = p.charAt(i);
            if (!(c == '.' || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')))
                return false;
        }
        return true;
    }

    private static String safe(String s) {
        if (s == null) return "";
        return s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
    }

    /**
     * versionCode of a package. Reflection keeps API &lt; 28 — where only the
     * deprecated int field exists — working.
     */
    private static long versionCodeOf(PackageInfo pi) {
        try {
            Object o = PackageInfo.class.getMethod("getLongVersionCode").invoke(pi);
            if (o instanceof Long) return (Long) o;
        } catch (Throwable ignored) {
            // API < 28: fall through to the int field below
        }
        return pi.versionCode;
    }

    private static String pngBase64(Bitmap bmp) {
        ByteArrayOutputStream baos = new ByteArrayOutputStream(32 * 1024);
        if (!bmp.compress(Bitmap.CompressFormat.PNG, 100, baos)) return "";
        return Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP);
    }

    private static Bitmap renderIcon(PackageManager pm, String pkg) {
        return renderDrawable(appIcon(pm, pkg));
    }

    private static Drawable appIcon(PackageManager pm, String pkg) {
        // 1) The normal path.
        try {
            Drawable d = pm.getApplicationIcon(pkg);
            if (d != null) return d;
        } catch (Throwable t) {
            // fall through
        }
        // 2) Some packages resolve through ApplicationInfo but not through the
        //    string overload (visibility / default-icon edge cases).
        try {
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            if (ai != null) {
                Drawable d = ai.loadIcon(pm);
                if (d != null) return d;
            }
        } catch (Throwable t) {
            // fall through to activity icon
        }
        // 3) Fallback: some apps expose the icon only on a launcher activity.
        try {
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.addCategory(Intent.CATEGORY_LAUNCHER);
            intent.setPackage(pkg);
            List<ResolveInfo> acts = pm.queryIntentActivities(intent, 0);
            if (acts != null) {
                for (ResolveInfo ri : acts) {
                    try {
                        if (ri != null && ri.activityInfo != null) {
                            Drawable d = ri.activityInfo.loadIcon(pm);
                            if (d != null) return d;
                        }
                    } catch (Throwable t) {
                        // try next activity
                    }
                }
            }
        } catch (Throwable t) {
            // no launcher activity or query failed
        }
        return null;
    }

    private static Bitmap renderDrawable(Drawable d) {
        if (d == null) return null;
        try {
            Bitmap b = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(b);
            if (d instanceof BitmapDrawable) {
                Bitmap src = ((BitmapDrawable) d).getBitmap();
                if (src != null && src.getWidth() > 0 && src.getHeight() > 0) {
                    // contain (min) so non-square legacy bitmaps are never stretched
                    float scale = Math.min(ICON_PX / (float) src.getWidth(), ICON_PX / (float) src.getHeight());
                    float w = src.getWidth() * scale, h = src.getHeight() * scale;
                    android.graphics.RectF dst = new android.graphics.RectF(
                            (ICON_PX - w) / 2f, (ICON_PX - h) / 2f,
                            (ICON_PX + w) / 2f, (ICON_PX + h) / 2f);
                    c.drawBitmap(src, null, dst, null);
                    return trimFill(b);
                }
            }
            if (Build.VERSION.SDK_INT >= 26 && d instanceof AdaptiveIconDrawable) {
                AdaptiveIconDrawable ad = (AdaptiveIconDrawable) d;
                Drawable bg = ad.getBackground(), fg = ad.getForeground();
                // Transparent canvas by default (bitmap starts transparent):
                // a fake white background looks boxed next to real icons.
                // Missing layers are simply skipped.
                if (bg != null) {
                    bg.setBounds(0, 0, ICON_PX, ICON_PX);
                    bg.draw(c);
                }
                if (fg != null) {
                    fg.setBounds(0, 0, ICON_PX, ICON_PX);
                    fg.draw(c);
                }
            } else {
                d.setBounds(0, 0, ICON_PX, ICON_PX);
                d.draw(c);
            }
            return trimFill(b);
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Launcher look, not letterboxed: many ROMs (MIUI/HyperOS) hand back a
     * pre-masked icon that occupies only ~82% of the canvas with a transparent
     * margin, so a contain-fit row shows a shrunken icon. Trim the fully
     * transparent border (never visible pixels), then scale the trimmed region
     * back up to fill ICON_PX. Aspect is preserved (min-scale, centred) so a
     * rounded-square mask stays a rounded square touching every edge.
     */
    private static Bitmap trimFill(Bitmap src) {
        int w = src.getWidth(), h = src.getHeight();
        if (w <= 0 || h <= 0) return src;
        int minX = w, minY = h, maxX = -1, maxY = -1;
        int[] row = new int[w];
        for (int y = 0; y < h; y++) {
            src.getPixels(row, 0, w, 0, y, w, 1);
            for (int x = 0; x < w; x++) {
                if ((row[x] >>> 24) > 8) {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX < 0) return src;                 // fully transparent: leave as-is
        int cw = maxX - minX + 1, ch = maxY - minY + 1;
        if (cw >= w && ch >= h) return src;       // already full-bleed
        Bitmap out = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(out);
        android.graphics.Rect srcR = new android.graphics.Rect(minX, minY, maxX + 1, maxY + 1);
        float sc = Math.min(ICON_PX / (float) cw, ICON_PX / (float) ch);
        float dw = cw * sc, dh = ch * sc;
        android.graphics.RectF dst = new android.graphics.RectF(
                (ICON_PX - dw) / 2f, (ICON_PX - dh) / 2f,
                (ICON_PX + dw) / 2f, (ICON_PX + dh) / 2f);
        c.drawBitmap(src, srcR, dst, null);
        return out;
    }
}
