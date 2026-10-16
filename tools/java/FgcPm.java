import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
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
 *   app_process -Djava.class.path=/data/adb/fgc/bin/fgc-pm.dex /system/bin FgcPm <list|icon|ping> [pkg]
 *
 * Uses real PackageManager (labels + icons on every ROM, no dumpsys roulette).
 * All output is single-line tab-separated; icons as base64 PNG (144px).
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
            System.err.println("usage: FgcPm list|icon <pkg>|ping");
            System.exit(2);
        }
        PackageManager pm = systemPackageManager();
        if ("ping".equals(args[0])) {
            System.out.println("pong");
        } else if ("list".equals(args[0]) && args.length == 1) {
            List<ApplicationInfo> apps = pm.getInstalledApplications(0);
            for (ApplicationInfo ai : apps) {
                String label = safe(String.valueOf(ai.loadLabel(pm)));
                boolean sys = (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0
                        && (ai.flags & ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0;
                System.out.println(ai.packageName + "\t" + label + "\t" + (sys ? "system" : "user"));
            }
        } else if ("icon".equals(args[0]) && args.length == 2 && validPkg(args[1])) {
            Bitmap bmp = renderIcon(pm, args[1]);
            if (bmp == null) System.exit(1);
            ByteArrayOutputStream baos = new ByteArrayOutputStream(32 * 1024);
            if (!bmp.compress(Bitmap.CompressFormat.PNG, 100, baos)) System.exit(1);
            System.out.println(Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP));
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

    private static Bitmap renderIcon(PackageManager pm, String pkg) {
        return renderDrawable(appIcon(pm, pkg));
    }

    private static Drawable appIcon(PackageManager pm, String pkg) {
        try {
            Drawable d = pm.getApplicationIcon(pkg);
            if (d != null) return d;
        } catch (Throwable t) {
            // fall through to activity icon
        }
        // Fallback: some apps expose the icon only on a launcher activity.
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
            if (d instanceof BitmapDrawable) {
                Bitmap src = ((BitmapDrawable) d).getBitmap();
                if (src != null && src.getWidth() > 0 && src.getHeight() > 0) {
                    Bitmap b = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888);
                    Canvas c = new Canvas(b);
                    float scale = Math.max(ICON_PX / (float) src.getWidth(), ICON_PX / (float) src.getHeight());
                    float w = src.getWidth() * scale, h = src.getHeight() * scale;
                    android.graphics.RectF dst = new android.graphics.RectF(
                            (ICON_PX - w) / 2f, (ICON_PX - h) / 2f,
                            (ICON_PX + w) / 2f, (ICON_PX + h) / 2f);
                    c.drawBitmap(src, null, dst, null);
                    return b;
                }
            }
            Bitmap b = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(b);
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
            return b;
        } catch (Throwable t) {
            return null;
        }
    }
}
