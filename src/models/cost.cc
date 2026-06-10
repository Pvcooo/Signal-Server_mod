/*****************************************************************************
*  COST231-HATA MODEL for Signal Server by Alex Farrant			     *
*  30 December 2013i							     *
*  This program is free software; you can redistribute it and/or modify it   *
*  under the terms of the GNU General Public License as published by the     *
*  Free Software Foundation; either version 2 of the License or any later    *
*  version.								     *
*									     *
*  This program is distributed in the hope that it will useful, but WITHOUT  *
*  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or     *
*  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License     *
*  for more details.							     *
*									     */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>

double COST231pathLoss(float f, float TxH, float RxH, float d, int mode)
{

	int C = 3;
	float lRxH = log10(11.75 * RxH);
	float C_H = 3.2 * (lRxH * lRxH) - 4.97;
	int c0 = 69.55;
	int cf = 26.16;
	if (f > 1500) {
		c0 = 46.3;
		cf = 33.9;
	}
	if (mode == 2) {
		C = 0;
		lRxH = log10(1.54 * RxH);
		C_H = 8.29 * (lRxH * lRxH) - 1.1;
	}
	if (mode == 3) {
		C = -3;
		C_H = (1.1 * log10(f) - 0.7) * RxH - (1.56 * log10(f)) + 0.8;
	}
	float logf = log10(f);
	double dbloss =
	    c0 + (cf * logf) - (13.82 * log10(TxH)) - C_H + (44.9 -
							     6.55 *
							     log10(TxH)) *
	    log10(d) + C;
	return dbloss;
}
