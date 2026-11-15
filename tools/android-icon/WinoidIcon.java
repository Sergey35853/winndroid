import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;

import java.io.FileOutputStream;
import java.lang.reflect.Method;
import java.util.List;

public class WinoidIcon {
    public static void main(String[] args) {
        if (args.length < 1) {
            System.err.println("usage: WinoidIcon --list | <package> <out.png>");
            System.exit(2);
        }
        try {
            Looper.prepare();
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method systemMain = at.getDeclaredMethod("systemMain");
            systemMain.setAccessible(true);
            Object thread = systemMain.invoke(null);

            Method getSystemContext = at.getDeclaredMethod("getSystemContext");
            getSystemContext.setAccessible(true);
            Context context = (Context) getSystemContext.invoke(thread);
            if (context == null) throw new IllegalStateException("no system context");

            PackageManager pm = context.getPackageManager();

            if ("--list".equals(args[0])) {
                Intent intent = new Intent(Intent.ACTION_MAIN);
                intent.addCategory(Intent.CATEGORY_LAUNCHER);
                List<ResolveInfo> apps = pm.queryIntentActivities(intent, 0);
                for (ResolveInfo ri : apps) {
                    if (ri.activityInfo == null) continue;
                    String pkg = ri.activityInfo.packageName;
                    CharSequence label = ri.loadLabel(pm);
                    String name = label == null ? pkg : label.toString();
                    name = name.replace('\t', ' ').replace('\r', ' ').replace('\n', ' ').trim();
                    if (name.length() == 0) name = pkg;
                    System.out.println(name + "\t" + pkg);
                }
                return;
            }

            if (args.length < 2) {
                System.err.println("usage: WinoidIcon --list | <package> <out.png>");
                System.exit(2);
            }
            String pkg = args[0];
            String out = args[1];
            Drawable drawable = pm.getApplicationIcon(pkg);
            int size = 256;
            Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, size, size);
            drawable.draw(canvas);

            FileOutputStream fos = new FileOutputStream(out);
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, fos);
            fos.close();
            bitmap.recycle();
            System.out.println("OK " + out);
        } catch (Throwable t) {
            t.printStackTrace();
            System.exit(1);
        }
    }
}
