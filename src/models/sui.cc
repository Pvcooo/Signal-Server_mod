#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static __inline float _20log10f(float x)
{
  return(8.685889f*logf(x));
}

double SUIpathLoss(double f, double TxH, double RxH, double d, int mode)
{

        d *= 1e3;

        float a = 4.6;
        float b = 0.0075;
        float c = 12.6;
        float s = 8.2;
        float XhCF = -10.8;

        if (mode == 2) {
                a = 4.0;
                b = 0.0065;
                c = 17.1;
		XhCF = -10.8;
        }
        if (mode == 3) {
                a = 3.6;
                b = 0.005;
                c = 20;
                XhCF = -20;
        }
        float d0 = 100.0;
        float A = _20log10f((4 * M_PI * d0) / (300.0 / f));
        float y = a - (b * TxH) + (c / TxH);

        float Xf = 0;
        float Xh = 0;

	if(f>2000){
		Xf=6.0 * log10(f / 2.0);
		Xh=XhCF * log10(RxH / 2.0);
	}
        return A + (10 * y) * (log10(d / d0)) + Xf + Xh + s;
}
