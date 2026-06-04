/* Verify that the Darwin driver on aarch64 (Apple Silicon) rejects a
   request for a single foreign architecture instead of silently
   producing a wrong-architecture binary.  See darwin_driver_init in
   gcc/config/darwin-driver.cc.  */

/* { dg-do compile { target aarch64*-*-darwin* } } */
/* { dg-options "-arch x86_64" } */
/* { dg-error "this compiler does not support the requested architecture; only '-arch arm64' is supported" "" { target *-*-* } 0 } */

int main () { return 0; }
