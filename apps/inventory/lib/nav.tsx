"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

const ITEMS = [
  { href: "/", label: "Dashboard" },
  { href: "/products", label: "Products" },
  { href: "/stock", label: "Stock" },
  { href: "/purchases", label: "Purchases" },
  { href: "/stock/transfers", label: "Transfers" },
  { href: "/stock/count", label: "Stock count" },
  { href: "/reports", label: "Reports" },
  { href: "/settings", label: "Settings" },
];

export function Nav() {
  const path = usePathname();
  const active = (h: string) => (h === "/" ? path === "/" : h === "/stock" ? path === "/stock" : path.startsWith(h));
  return (
    <nav>
      {ITEMS.map((i) => (
        <Link key={i.href} href={i.href}
          className={"nav-item" + (active(i.href) ? " active" : "")}>
          {i.label}
        </Link>
      ))}
    </nav>
  );
}
