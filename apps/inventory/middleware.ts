import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";

const PUBLIC = ["/login", "/api/health"];

export async function middleware(req: NextRequest) {
  const res = NextResponse.next({ request: req });
  const supa = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => req.cookies.getAll(),
        setAll: (all) => all.forEach(({ name, value, options }) =>
          res.cookies.set(name, value, options)),
      },
    },
  );
  const { data: { user } } = await supa.auth.getUser();
  const path = req.nextUrl.pathname;
  const isPublic = PUBLIC.some((p) => path.startsWith(p));

  if (!user && !isPublic)
    return NextResponse.redirect(new URL("/login", req.url));
  if (user && path.startsWith("/login"))
    return NextResponse.redirect(new URL("/", req.url));
  // Signed in but no business yet -> onboarding, and nowhere else.
  const orgId = (user?.app_metadata as { org_id?: string } | undefined)?.org_id;
  if (user && !orgId && !path.startsWith("/onboarding") && !isPublic)
    return NextResponse.redirect(new URL("/onboarding", req.url));
  if (user && orgId && path.startsWith("/onboarding"))
    return NextResponse.redirect(new URL("/", req.url));
  return res;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|ico)$).*)"],
};
