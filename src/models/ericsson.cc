#include <stdio.h>
#include <stdlib.h>
#include <math.h>

double EricssonpathLoss(float f, float TxH, float RxH, float d, int mode)
{

	double a0 = 36.2, a1 = 30.2, a2 = -12, a3 = 0.1;

	if (mode == 2) {
		a0 = 43.2;
		a1 = 68.93;
	}
	if (mode == 1) {
		a0 = 45.95;
		a1 = 100.6;
	}
	double g1 = 3.2 * (log10(11.75 * RxH) * log10(11.75 * RxH));
	double g2 = 44.49 * log10(f) - 4.78 * (log10(f) * log10(f));

	return a0 + a1 * log10(d) + a2 * log10(TxH) + a3 * log10(TxH) * log10(d) - g1 + g2;
}
