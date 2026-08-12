"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

const ITEMS = [
  { href: "/", label: "Dashboard" },
  { href: "/products", label: "Products" },
  { href: "/stock", label: "Stock" },
  { href: "/settings", label: "Settings" },
];

export function Nav() {
  const path = usePathname();
  return (
    <nav>
      {ITEMS.map((i) => (
        <Link key={i.href} href={i.href}
          className={"nav-item" + (path === i.href ? " active" : "")}>
          {i.label}
        </Link>
      ))}
    </nav>
  );
}
