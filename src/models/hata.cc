/*****************************************************************************
*  HATA MODEL for Signal Server by Alex Farrant                              *
*  30 December 2013							     *
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

#include <math.h>

double HATApathLoss(float f, float h_B, float h_M, float d, int mode)
{

float lh_M;
float C_H;
float logf = log10(f);

	if(f<200){
		lh_M = log10(1.54 * h_M);
		C_H = 8.29 * (lh_M * lh_M) - 1.1;
	}else{
		lh_M = log10(11.75 * h_M);
		C_H = 3.2 * (lh_M * lh_M) - 4.97;
	}

	float L_u = 69.55 + 26.16 * logf - 13.82 * log10(h_B) - C_H + (44.9 - 6.55 * log10(h_B)) * log10(d);

	if (!mode || mode == 1) {
		return L_u;
	}

	if (mode == 2) {
		float logf_28 = log10(f / 28);
		return L_u - 2 * logf_28 * logf_28 - 5.4;
	}

	if (mode == 3) {
		return L_u - 4.78 * logf * logf + 18.33 * logf - 40.94;
	}

	return 0;
}
