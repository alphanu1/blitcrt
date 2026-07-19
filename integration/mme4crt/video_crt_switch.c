/* CRT SwitchRes Core
 *  Copyright (C) 2018 Alphanu / Ben Templeman.
 *
 * RetroArch - A frontend for libretro.
 *  Copyright (C) 2010-2014 - Hans-Kristian Arntzen
 *  Copyright (C) 2011-2017 - Daniel De Matteis
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <libretro.h>
#include <math.h>

#include <retro_common_api.h>
#include <compat/strl.h>
#include <string/stdstring.h>

#include "gfx_display.h"
#include "video_crt_switch.h"
#include "video_display_server.h"
#include "../core_info.h"
#include "../verbosity.h"
#include "../file_path_special.h"
#include "../paths.h"

#include "../deps/switchres/switchres_wrapper.h"
static sr_mode srm;

/* ---------------------------------------------------------------------------
 * CRT1 FPGA / CRTPi backend (self-contained, C89).
 *
 * When an FPGA (FT2232H) or CRTPi USB device is present, RetroArch drives
 * it directly: switchres still computes the modeline, but instead of (or
 * as well as) a host modeswitch we send CMD_SET_PLL + CMD_SET_MODE and
 * stream frames over the wire. Gated by HAVE_CRT_FPGA; without it every
 * crt_fpga_* call is a no-op and native switching is unchanged.
 * ------------------------------------------------------------------------- */
/* Always compiled for now (no HAVE_CRT_FPGA gate) -- requires linking
 * -lftdi1. crt_fpga_on stays false until crt_fpga_init() finds a device,
 * so behaviour is unchanged when nothing is attached. */
#include <libftdi1/ftdi.h>

#define CRT_FPGA_MAGIC   0x31545243u
#define CRT_FPGA_REF_HZ  50000000UL
#define CRT_FPGA_VID     0x0403
#define CRT_FPGA_PID     0x6010

static struct ftdi_context *crt_fpga_ftdi = NULL;
static bool                 crt_fpga_on   = false;

static void crt_fpga_put32(unsigned char *p, unsigned long v)
{
   p[0] = (unsigned char)(v & 0xFF);
   p[1] = (unsigned char)((v >> 8) & 0xFF);
   p[2] = (unsigned char)((v >> 16) & 0xFF);
   p[3] = (unsigned char)((v >> 24) & 0xFF);
}

static void crt_fpga_put16(unsigned char *p, unsigned v)
{
   p[0] = (unsigned char)(v & 0xFF);
   p[1] = (unsigned char)((v >> 8) & 0xFF);
}

static int crt_fpga_raw(const unsigned char *buf, int len)
{
   int n;
   if (!crt_fpga_ftdi)
      return -1;
   n = ftdi_write_data(crt_fpga_ftdi, (unsigned char *)buf, len);
   return (n == len) ? n : -1;
}

static int crt_fpga_pkt(unsigned char cmd,
      const unsigned char *payload, unsigned long len)
{
   unsigned char hdr[12];
   crt_fpga_put32(hdr + 0, CRT_FPGA_MAGIC);
   hdr[4] = cmd; hdr[5] = 0; hdr[6] = 0; hdr[7] = 0;
   crt_fpga_put32(hdr + 8, len);
   if (crt_fpga_raw(hdr, 12) < 0)
      return -1;
   if (len && crt_fpga_raw(payload, (int)len) < 0)
      return -1;
   return 0;
}

/* integer M/N/C divider search: pclk = ref*m/(n*c), VCO 600-1300MHz,
 * PFD floor 5MHz. Fills m,n,c; returns achieved Hz. */
static unsigned long crt_fpga_pll_search(unsigned long ref_hz,
      unsigned long target_hz, unsigned *m_out, unsigned *n_out,
      unsigned *c_out)
{
   double   best_err = 1e30;
   double   best_ach = 0.0;
   unsigned bm = 0, bn = 1, bc = 1;
   unsigned n, m, cc;

   for (n = 1; n <= 10; n++)
   {
      double   pfd = (double)ref_hz / n;
      unsigned m_lo, m_hi;
      if (pfd < 5000000.0)
         continue;
      m_lo = (unsigned)(600000000.0 / pfd);
      if (m_lo < 1)
         m_lo = 1;
      m_hi = (unsigned)(1300000000.0 / pfd) + 1;
      if (m_hi > 512)
         m_hi = 512;
      for (m = m_lo; m <= m_hi; m++)
      {
         double   vco = pfd * m;
         unsigned c0;
         if (vco < 600000000.0 || vco > 1300000000.0)
            continue;
         c0 = (unsigned)(vco / target_hz + 0.5);
         for (cc = (c0 > 1 ? c0 - 1 : 1); cc <= c0 + 1 && cc <= 512; cc++)
         {
            double ach = vco / cc;
            double err = ach - (double)target_hz;
            if (err < 0)
               err = -err;
            if (err < best_err)
            {
               best_err = err;
               best_ach = ach;
               bm = m; bn = n; bc = cc;
            }
         }
      }
   }
   *m_out = bm; *n_out = bn; *c_out = bc;
   return (unsigned long)(best_ach + 0.5);
}

/* Probe for a device once. Safe when libs/device absent. */
static bool crt_fpga_init(void)
{
   if (crt_fpga_on)
      return true;
   crt_fpga_ftdi = ftdi_new();
   if (!crt_fpga_ftdi)
      return false;
   ftdi_set_interface(crt_fpga_ftdi, INTERFACE_A);
   if (ftdi_usb_open(crt_fpga_ftdi, CRT_FPGA_VID, CRT_FPGA_PID) < 0)
   {
      ftdi_free(crt_fpga_ftdi);
      crt_fpga_ftdi = NULL;
      return false;
   }
   ftdi_set_bitmode(crt_fpga_ftdi, 0x00, BITMODE_RESET);
   crt_fpga_on = true;
   RARCH_LOG("[CRT] FPGA CRT1 device detected; native switching bypassed.\n");
   return true;
}

/* Push an sr_mode to the device: SET_PLL then SET_MODE. */
static bool crt_fpga_set_mode(const sr_mode *m)
{
   unsigned char p[32];
   unsigned      mm, nn, cc;
   unsigned      flags = 0;

   if (!crt_fpga_on || !m)
      return false;

   crt_fpga_pll_search(CRT_FPGA_REF_HZ, (unsigned long)m->pclock,
         &mm, &nn, &cc);
   {
      unsigned char pll[12];
      crt_fpga_put32(pll + 0, mm);
      crt_fpga_put32(pll + 4, nn);
      crt_fpga_put32(pll + 8, cc);
      crt_fpga_pkt(0x11 /* SET_PLL */, pll, 12);
   }

   if (m->interlace)
      flags |= 1;
   crt_fpga_put32(p + 0,  (unsigned long)m->pclock);
   crt_fpga_put16(p + 4,  m->width);
   crt_fpga_put16(p + 6,  m->hbegin);
   crt_fpga_put16(p + 8,  m->hend);
   crt_fpga_put16(p + 10, m->htotal);
   crt_fpga_put16(p + 12, m->height);
   crt_fpga_put16(p + 14, m->vbegin);
   crt_fpga_put16(p + 16, m->vend);
   crt_fpga_put16(p + 18, m->vtotal);
   crt_fpga_put16(p + 20, flags);
   p[22] = 1;              /* RGB565 */
   p[23] = 0;
   crt_fpga_put32(p + 24, 0);
   crt_fpga_put32(p + 28, 0);
   return crt_fpga_pkt(0x10 /* SET_MODE */, p, 32) == 0;
}

/* Stream one finished frame (RGB565), stripping pitch padding. */
static bool crt_fpga_send_frame(const void *pixels,
      unsigned width, unsigned height, unsigned pitch)
{
   unsigned char fhdr[12 + 16];
   const unsigned char *src = (const unsigned char *)pixels;
   unsigned y;

   if (!crt_fpga_on || !pixels)
      return false;

   crt_fpga_put32(fhdr + 0, CRT_FPGA_MAGIC);
   fhdr[4] = 0x20 /* FRAME */; fhdr[5] = 0; fhdr[6] = 0; fhdr[7] = 0;
   crt_fpga_put32(fhdr + 8,  (unsigned long)(16 + (size_t)width * height * 2));
   crt_fpga_put32(fhdr + 12, 0);
   crt_fpga_put32(fhdr + 16, 0);
   crt_fpga_put32(fhdr + 20, width);
   crt_fpga_put32(fhdr + 24, height);
   if (crt_fpga_raw(fhdr, 12 + 16) < 0)
      return false;
   for (y = 0; y < height; y++)
      if (crt_fpga_raw(src + (size_t)y * pitch, (int)(width * 2)) < 0)
         return false;
   return true;
}

static void crt_fpga_deinit(void)
{
   if (crt_fpga_ftdi)
   {
      ftdi_usb_close(crt_fpga_ftdi);
      ftdi_free(crt_fpga_ftdi);
      crt_fpga_ftdi = NULL;
   }
   crt_fpga_on = false;
}


#ifdef HAVE_CONFIG_H
#include "../config.h"
#endif

/* Forward declarations */
static void crt_adjust_sr_ini(videocrt_switch_t *p_switch);

/* Global local variables */
static bool ini_overrides_loaded = false;
static char core_name[NAME_MAX_LENGTH]; /* Same size as library_name on retroarch_data.h */
static char content_dir[DIR_MAX_LENGTH];
static char current_content_name[256];
static char content_name[256];
static char _hSize[12];
static char _hShift[12];
static char _vShift[12];

#if defined(HAVE_VIDEOCORE) /* Need to add video core to SR2 */
#include <interface/vmcs_host/vc_vchi_gencmd.h>
static void crt_rpi_switch(videocrt_switch_t *p_switch,int width, int height, float hz, int xoffset, int native_width);
#endif

static bool crt_check_for_changes(videocrt_switch_t *p_switch)
{
   if (   (p_switch->ra_core_height != p_switch->ra_tmp_height)
       || (p_switch->ra_core_width  != p_switch->ra_tmp_width)
       || (p_switch->center_adjust  != p_switch->tmp_center_adjust)
       || (p_switch->porch_adjust   != p_switch->tmp_porch_adjust)
       || (p_switch->vert_adjust   != p_switch->tmp_vert_adjust)
       || (p_switch->ra_core_hz     != p_switch->ra_tmp_core_hz)
       || (p_switch->rotated        != p_switch->tmp_rotated))
      return true;
   return false;
}

static void crt_store_temp_changes(videocrt_switch_t *p_switch)
{
   p_switch->ra_tmp_height     = p_switch->ra_core_height;
   p_switch->ra_tmp_width      = p_switch->ra_core_width;
   p_switch->tmp_center_adjust = p_switch->center_adjust;
   p_switch->tmp_porch_adjust  = p_switch->porch_adjust;
   p_switch->ra_tmp_core_hz    = p_switch->ra_core_hz;
   p_switch->tmp_rotated       = p_switch->rotated;
   p_switch->tmp_vert_adjust   = p_switch->vert_adjust;
}

static void crt_aspect_ratio_switch(
      videocrt_switch_t *p_switch,
      unsigned width, unsigned height,
      float srm_width, float srm_height,
      unsigned video_aspect_ratio_idx)
{
   float fly_aspect               = (float)width / (float)height;
   p_switch->fly_aspect           = fly_aspect;
   video_driver_state_t *video_st = video_state_get_ptr();

   /* We only force aspect ratio for the core provided setting */
   if (video_aspect_ratio_idx != ASPECT_RATIO_CORE)
   {
      RARCH_LOG("[CRT] Aspect ratio forced by user: %f.\n", video_st->aspect_ratio);
      return;
   }

   /* Send aspect float to video_driver */
   video_st->aspect_ratio         = fly_aspect;
   RARCH_LOG("[CRT] Setting aspect ratio: %f.\n", fly_aspect);
   RARCH_LOG("[CRT] Setting screen size: %dx%d.\n",
         width, height);
   video_driver_set_output_size(width, height);
   if (video_st->current_video && video_st->current_video->set_viewport)
      video_st->current_video->set_viewport(
            video_st->data, width, height, true, true);

   command_event(CMD_EVENT_VIDEO_APPLY_STATE_CHANGES, NULL);
}

static void crt_switch_set_aspect(
      videocrt_switch_t *p_switch,
      unsigned int width, unsigned int height,
      unsigned int srm_width, unsigned srm_height,
      float srm_xscale, float srm_yscale,
      bool srm_isstretched )
{
   sr_state state;
   unsigned int patched_width  = 0;
   unsigned int patched_height = 0;
   int scaled_width            = 0;
   int scaled_height           = 0;

   /* used to fix aspect should SR not find a resolution */
   if (srm_width == 0)
   {
      video_driver_get_output_size(&patched_width, &patched_height);
      srm_xscale               = 1;
      srm_yscale               = 1;
   }
   else
   {
      /* use native values as we will be multiplying by srm scale later. */
      patched_width            = width;
      patched_height           = height;
   }

#if !defined(HAVE_VIDEOCORE)
   sr_get_state(&state);

   if ((int)srm_width >= state.super_width && !srm_isstretched)
      RARCH_LOG("[CRT] Super resolution detected. Fractal scaling @ X:%f Y:%f.\n", srm_xscale, srm_yscale);
   else if (srm_isstretched && srm_width > 0 )
      RARCH_LOG("[CRT] Resolution is stretched. Fractal scaling @ X:%f Y:%f.\n", srm_xscale, srm_yscale);
#endif

   scaled_width  = roundf(patched_width  * srm_xscale);
   scaled_height = roundf(patched_height * srm_yscale);

   crt_aspect_ratio_switch(p_switch, scaled_width, scaled_height,
         srm_width, srm_height,
         config_get_ptr()->uints.video_aspect_ratio_idx);
}

#if !defined(HAVE_VIDEOCORE)
static bool crt_sr2_init(videocrt_switch_t *p_switch,
      int monitor_index, unsigned int crt_mode, unsigned int super_width)
{
   char index[10];
   gfx_ctx_ident_t gfxctx;
   char ra_config_path[PATH_MAX_LENGTH];
   char sr_ini_file[PATH_MAX_LENGTH];

   if (monitor_index+1 >= 0 && monitor_index+1 < 10)
      snprintf(index, sizeof(index), "%d", monitor_index);
   else
      strlcpy(index, "0", sizeof(index));

   video_context_driver_get_ident(&gfxctx);

   p_switch->kms_ctx = (gfxctx.ident && strncmp(gfxctx.ident, "kms", 3) == 0);
   p_switch->khr_ctx = (gfxctx.ident && strncmp(gfxctx.ident, "khr_display", 11) == 0);

   RARCH_LOG("[CRT] Video context is: %s.\n", gfxctx.ident);

   if (!p_switch->sr2_active)
   {
      void (*logp)(const char *, ...) = &RARCH_LOG;
      void (*dbgp)(const char *, ...) = &RARCH_DBG;
      void (*errp)(const char *, ...) = &RARCH_ERR;
      sr_init();
      crt_fpga_init();   /* probe for an FPGA/CRTPi CRT1 device */
      sr_set_log_callback_info(*(void **)(&logp));
      sr_set_log_callback_debug(*(void **)(&dbgp));
      sr_set_log_callback_error(*(void **)(&errp));

      switch (crt_mode)
      {
         case 1:
            sr_set_monitor("arcade_15");
            RARCH_LOG("[CRT] CRT mode: %d - arcade_15.\n", crt_mode);
            break;
         case 2:
            sr_set_monitor("arcade_31");
            RARCH_LOG("[CRT] CRT mode: %d - arcade_31.\n", crt_mode);
            break;
         case 3:
            sr_set_monitor("pc_31_120");
            RARCH_LOG("[CRT] CRT mode: %d - pc_31_120.\n", crt_mode);
            break;
         case 4:
            RARCH_LOG("[CRT] CRT mode: %d - Selected from ini.\n", crt_mode);
            break;
         default:
            break;
      }

      if (super_width > 2)
      {
         char sw[16];
         sr_set_user_mode(super_width, 0, 0);
         snprintf(sw, sizeof(sw), "%d", super_width);
         sr_set_option(SR_OPT_SUPER_WIDTH, sw);
      }

      if (p_switch->kms_ctx)
            p_switch->rtn = sr_init_disp("dummy", NULL);
      else if (monitor_index + 1 > 0)
      {
         RARCH_LOG("[CRT] Monitor index manual: %s.\n", &index[0]);
         p_switch->rtn = sr_init_disp(index, NULL);
      }
      else
      {
         RARCH_LOG("[CRT] Monitor index auto: %s.\n", "auto");
         p_switch->rtn = sr_init_disp("auto", NULL);
      }

      RARCH_LOG("[CRT] SR rtn %d.\n", p_switch->rtn);

      if (p_switch->rtn >= 0)
      {
         core_name[0]   = '\0';
         content_dir[0] = '\0';
         /* For Lakka, check a switchres.ini next to user's retroarch.cfg */
         fill_pathname_application_data(ra_config_path, PATH_MAX_LENGTH);
         fill_pathname_join(sr_ini_file,
               ra_config_path, "switchres.ini", sizeof(sr_ini_file));
         if (path_is_valid(sr_ini_file))
         {
            RARCH_LOG("[CRT] Loading switchres.ini override file from \"%s\".\n", sr_ini_file);
            sr_load_ini(sr_ini_file);
         }
      }
   }

   if (p_switch->rtn >= 0)
   {
      if (!p_switch->kms_ctx)
      {
         p_switch->sr2_active = true;
         return true;
      }
      else if (p_switch->kms_ctx)
      {
         p_switch->sr2_active = true;
         RARCH_LOG("[CRT] KMS context detected, keeping SR alive.\n");
         return true;
      }
      else if (p_switch->khr_ctx)
      {
         p_switch->sr2_active = true;
         RARCH_LOG("[CRT] Vulkan context detected, keeping SR alive.\n");
         return true;
      }
   }

   RARCH_ERR("[CRT] Error at init, CRT modeswitching disabled.\n");
   sr_deinit();
   p_switch->sr2_active = false;

   return false;
}

static void get_modeline_for_kms(videocrt_switch_t *p_switch, sr_mode* srm)
{
   p_switch->clock       = srm->pclock / 1000;
   p_switch->hdisplay    = srm->width;
   p_switch->hsync_start = srm->hbegin;
   p_switch->hsync_end   = srm->hend;
   p_switch->htotal      = srm->htotal;
   p_switch->vdisplay    = srm->height;
   p_switch->vsync_start = srm->vbegin;
   p_switch->vsync_end   = srm->vend;
   p_switch->vtotal      = srm->vtotal;
   p_switch->vrefresh    = srm->refresh;
   p_switch->hskew       = 0;
   p_switch->vscan       = 0;
   p_switch->interlace   = srm->interlace;
   p_switch->doublescan  = srm->doublescan;
   p_switch->hsync       = srm->hsync;
   p_switch->vsync       = srm->vsync;
}

static void switch_res_crt(
      videocrt_switch_t *p_switch,
      unsigned width, unsigned height,
      unsigned crt_mode, unsigned native_width,
      int monitor_index, int super_width)
{
   int w                   = native_width;
   int h                   = height;

   /* Check if SR2 is loaded, if not, load it */
   if (crt_sr2_init(p_switch, monitor_index, crt_mode, super_width))
   {
      int ret;
      int flags = 0;
      int temph = 640;
      int tempw = 480;
      char current_core_name[NAME_MAX_LENGTH];
      char current_content_dir[DIR_MAX_LENGTH];
      double rr              = p_switch->ra_core_hz;
      const char *_core_name = (const char*)runloop_state_get_ptr()->system.info.library_name;



      const char* hSize = (const char*)_hSize;
      const char* hShift = (const char*)_hShift;
      const char* vShift = (const char*)_vShift;

      if (p_switch->rotated)
         flags |= SR_MODE_ROTATED;

      /* Check for core and content changes in case we need
         to make any adjustments */
      if (!_core_name || !*_core_name)
         current_core_name[0] = '\0';
      else
         strlcpy(current_core_name, _core_name, sizeof(current_core_name));

      fill_pathname_parent_dir_name(current_content_dir,
            path_get(RARCH_PATH_CONTENT),
            sizeof(current_content_dir));

      if (     !string_is_equal(core_name,   current_core_name)
            || !string_is_equal(content_dir, current_content_dir)
            || !string_is_equal(current_content_name ,content_name))
      {
         /* A core or content change was detected,
            we update the current values and make adjustments */
         strlcpy(core_name,   current_core_name,   sizeof(core_name));
         strlcpy(content_dir, current_content_dir, sizeof(content_dir));
         strlcpy(content_name, current_content_name, sizeof(current_content_name));
         RARCH_LOG("[CRT] Current running core: %s.\n", core_name);
         crt_adjust_sr_ini(p_switch);
         p_switch->hh_core = false;
      }

      #if defined(_WIN32)
      if (p_switch->center_adjust  != p_switch->tmp_center_adjust ||
         p_switch->vert_adjust   != p_switch->tmp_vert_adjust)
      {

         if (w > 320 || h > 240)
         {
            temph = 240;
            tempw = 320;
            RARCH_LOG("[CRT] SR temporary mode for windows geometry adjustment (320x240).\n");
         }else{

            RARCH_LOG("[CRT] SR temporary mode for windows geometry adjustment (640x400).\n");
         }

         ret = sr_add_mode(tempw, temph, rr, flags, &srm);

         if (!ret)
            RARCH_ERR("[CRT] SR failed to add temporary mode for windows geometry adjustment.\n");
         else
         {
            ret = sr_set_mode(srm.id);
            RARCH_LOG("[CRT] SR added temporary mode for windows geometry adjustment.\n");
         }

      }
      #endif

      sr_set_option(SR_OPT_H_SIZE, hSize);
      sr_set_option(SR_OPT_H_SHIFT, hShift);
      sr_set_option(SR_OPT_V_SHIFT, vShift);

      RARCH_DBG("[CRT] %dx%d rotation: %d rotated: %d core rotation:%d\n", w, h, p_switch->rotated, flags & SR_MODE_ROTATED, retroarch_get_rotation());
      ret = sr_add_mode(w, h, rr, flags, &srm);
      if (!ret)
         RARCH_ERR("[CRT] SR failed to add mode.\n");
      if (crt_fpga_on)
      {
         /* FPGA/CRTPi is the display: send the modeline over CRT1,
            do NOT switch the host video mode. */
         crt_fpga_set_mode(&srm);
      }
      else if (p_switch->kms_ctx)
      {
         get_modeline_for_kms(p_switch, &srm);
         video_driver_set_video_mode(srm.width, srm.height, true);
      }
      else if (p_switch->khr_ctx)
         RARCH_WARN("[CRT] Vulkan -> Can't modeswitch for now.\n");
      else
         ret = sr_set_mode(srm.id);
      if (!p_switch->kms_ctx && !ret)
         RARCH_ERR("[CRT] SR failed to switch mode.\n");
      p_switch->sr_core_hz = (float)srm.vfreq;

      crt_switch_set_aspect(p_switch,
            p_switch->rotated ? h : w,
            p_switch->rotated ? w : h,
            srm.width, srm.height,
            (float)srm.x_scale,
            (float)srm.y_scale,
            srm.is_stretched);
   }
   else
   {
      crt_switch_set_aspect(p_switch,
            width, height,
            width, height,
            1.0f,
            1.0f,
            false);
      video_driver_set_output_size(width , height);
      command_event(CMD_EVENT_VIDEO_APPLY_STATE_CHANGES, NULL);
   }
}
#endif

/* Public: stream a finished frame to the FPGA/CRTPi when it owns the
   display. Call from the video path (see crt_send_frame in the header).
   No-op unless a device was detected. */
void crt_send_frame(const void *pixels, unsigned width,
      unsigned height, unsigned pitch)
{
   if (crt_fpga_on)
      crt_fpga_send_frame(pixels, width, height, pitch);
}

void crt_destroy_modes(videocrt_switch_t *p_switch)
{
   crt_fpga_deinit();

   if (p_switch->sr2_active)
   {
      p_switch->sr2_active = false;
      sr_deinit();
   }
}

void crt_switch_res_core(
      videocrt_switch_t *p_switch,
      unsigned native_width, unsigned width, unsigned height,
      float hz, bool rotated, unsigned crt_mode,
      int crt_switch_center_adjust,
      int crt_switch_porch_adjust,
      int monitor_index, bool dynamic,
      int super_width, bool hires_menu,
      unsigned video_aspect_ratio_idx,
      int crt_switch_vert_adjust)
{


   if (height <= 4)
   {
      hz              = 60;
      if (hires_menu)
      {
         native_width = 640;
         height       = 480;
      }
      else
      {
         native_width = 320;
         height       = 240;
      }
      width           = native_width;
   }

   if (height != 4 )
   {
      p_switch->menu_active           = false;
      p_switch->porch_adjust          = crt_switch_porch_adjust;
      p_switch->vert_adjust           = crt_switch_vert_adjust;
      p_switch->ra_core_height        = height;
      p_switch->ra_core_hz            = hz;

      p_switch->ra_core_width         = width;

      p_switch->center_adjust         = crt_switch_center_adjust;
      p_switch->index                 = monitor_index;
      p_switch->rotated               = rotated;

      /* Detect resolution change and switch */
      if (crt_check_for_changes(p_switch))
      {
         RARCH_LOG("[CRT] Requested resolution: %dx%d@%f, orientation: %s.\n",
                  native_width, height, hz, rotated? "rotated" : "normal");
#if defined(HAVE_VIDEOCORE)
         crt_rpi_switch(p_switch, width, height, hz, 0, native_width);
#else

         snprintf(_hSize, sizeof(_hSize), "%lf", 1+
               ((float)crt_switch_porch_adjust/100.0));
         snprintf(_hShift, sizeof(_hShift), "%d",
               crt_switch_center_adjust);
         snprintf(_vShift, sizeof(_vShift), "%d",
               crt_switch_vert_adjust);
         if (p_switch->hh_core)
         {
            int corrected_width  = 320;
            int corrected_height = 240;
            switch_res_crt(p_switch, corrected_width, corrected_height,
                  crt_mode, corrected_width, monitor_index-1, super_width);
            crt_switch_set_aspect(p_switch, native_width, height, native_width,
                  height ,(float)1,(float)1, false);
            video_driver_set_output_size(native_width , height);
         }
         else
            switch_res_crt(p_switch, p_switch->ra_core_width,
                  p_switch->ra_core_height, crt_mode,
                  native_width, monitor_index-1, super_width);
#endif
         video_monitor_set_refresh_rate(p_switch->sr_core_hz);
         crt_store_temp_changes(p_switch);
      }

      if (  (video_aspect_ratio_idx == ASPECT_RATIO_CORE)
         &&  video_driver_get_aspect_ratio() != p_switch->fly_aspect)
      {
         video_driver_state_t *video_st = video_state_get_ptr();
         float fly_aspect               = (float)p_switch->fly_aspect;
         RARCH_LOG("[CRT] Restoring aspect ratio: %f.\n", fly_aspect);
         video_st->aspect_ratio         = fly_aspect;
         command_event(CMD_EVENT_VIDEO_APPLY_STATE_CHANGES, NULL);
      }
   }
}

static char *get_game_name(char *full_path)
{
   unsigned i;
   size_t _len        = strlen(full_path);
   char* rom_filename = full_path + _len;
   char delim         = (char)  path_get(RARCH_PATH_BASENAME)[0];

   for (i = 0; i < _len; i++)
   {
      if (full_path[i] == '/' || full_path[i] =='\\')
      {
         delim = full_path[i];
         break;
      }
   }

   while (0 < _len && (full_path[--_len] != delim));
   if (full_path[_len] == delim)
      rom_filename = full_path + _len + 1;
   return rom_filename;
}

void crt_adjust_sr_ini(videocrt_switch_t *p_switch)
{
   char config_directory[DIR_MAX_LENGTH];
   char switchres_ini_override_file[PATH_MAX_LENGTH];

   char* rom_filename = get_game_name((char*) path_get(RARCH_PATH_BASENAME));

   strlcpy(content_name, rom_filename, sizeof(current_content_name));

   RARCH_LOG("[CRT] Game info \"%s\".\n", rom_filename);

   if (p_switch->sr2_active)
   {
      /* First we reload the base switchres.ini file
         to undo any overrides that might have been
         loaded for another core */
      if (ini_overrides_loaded)
      {
         RARCH_LOG("[CRT] Loading default switchres.ini...\n");
         sr_load_ini((char *)"switchres.ini");
         ini_overrides_loaded = false;
      }

      if (core_name[0] != '\0')
      {
         /* Then we look for config/Core Name/Core Name.switchres.ini
            and load it, overriding any variables it specifies */
         config_directory[0] = '\0';
         fill_pathname_application_special(config_directory,
               sizeof(config_directory),
               APPLICATION_SPECIAL_DIRECTORY_CONFIG);

         fill_pathname_join_special_ext(switchres_ini_override_file,
               config_directory, core_name, core_name,
               ".switchres.ini", sizeof(switchres_ini_override_file));

         if (path_is_valid(switchres_ini_override_file))
         {
            RARCH_LOG("[CRT] Loading switchres.ini core override file from \"%s\".\n", switchres_ini_override_file);
            sr_load_ini(switchres_ini_override_file);
            ini_overrides_loaded = true;
         }

         /* Next up we load directory overrides, if any */
         fill_pathname_join_special_ext(switchres_ini_override_file,
               config_directory, core_name, content_dir,
               ".switchres.ini", sizeof(switchres_ini_override_file));

         if (path_is_valid(switchres_ini_override_file))
         {
            RARCH_LOG("[CRT] Loading switchres.ini content directory override file from \"%s\".\n", switchres_ini_override_file);
            sr_load_ini(switchres_ini_override_file);
            ini_overrides_loaded = true;
         }

         /* Next up we load game overrides, if any */
         fill_pathname_join_special_ext(switchres_ini_override_file,
               config_directory, core_name, content_name,
               ".switchres.ini", sizeof(switchres_ini_override_file));

         if (path_is_valid(switchres_ini_override_file))
         {
            RARCH_LOG("[CRT] Loading switchres.ini game override file from \"%s\".\n", switchres_ini_override_file);
            sr_load_ini(switchres_ini_override_file);
            ini_overrides_loaded = true;
         }
      }
   }
}

/* only used for RPi3 */
#if defined(HAVE_VIDEOCORE)
static void crt_rpi_switch(videocrt_switch_t *p_switch,
      int width, int height, float hz,
      int xoffset, int native_width)
{
   int w;
   char buffer[1024];
   VCHI_INSTANCE_T vchi_instance;
   VCHI_CONNECTION_T *vchi_connection  = NULL;
   static char output1[250]            = {0};
   static char output2[250]            = {0};
   static char set_hdmi[250]           = {0};
   static char set_hdmi_timing[250]    = {0};
   int i                               = 0;
   int hfp                             = 0;
   int hsp                             = 0;
   int hbp                             = 0;
   int vfp                             = 0;
   int vsp                             = 0;
   int vbp                             = 0;
   int hmax                            = 0;
   int vmax                            = 0;
   int pdefault                        = 8;
   int pwidth                          = 0;
   int ip_flag                         = 0;
   float roundw                        = 0.0f;
   float roundh                        = 0.0f;
   float pixel_clock                   = 0.0f;
   int xscale                          = 1;
   int yscale                          = 1;

   if (height > 300)
      height /= 2;

   /* set core refresh from hz */
   video_monitor_set_refresh_rate(hz);

   crt_switch_set_aspect(p_switch, width,
      height, width, height,
      (float)1, (float)1, false);

   w = width;
   while (w < 1920)
      w = w+width;

   if (w > 2000)
      w = w - width;

   width = w;

   crt_aspect_ratio_switch(p_switch, width, height, width, height,
         config_get_ptr()->uints.video_aspect_ratio_idx);

   /* following code is the mode line generator */
   hfp      = ((width * 0.044f) + (width / 112));
   hbp      = ((width * 0.172f) + (width /64));

   hsp      = (width * 0.117f);

   if (height < 241)
      vmax = 261;
   if (height < 241 && hz > 56 && hz < 58)
      vmax = 280;
   if (height < 241 && hz < 55)
      vmax = 313;
   if (height > 250 && height < 260 && hz > 54)
      vmax = 296;
   if (height > 250 && height < 260 && hz > 52 && hz < 54)
      vmax = 285;
   if (height > 250 && height < 260 && hz < 52)
      vmax = 313;
   if (height > 260 && height < 300)
      vmax = 318;

   if (height > 400 && hz > 56)
      vmax = 533;
   if (height > 520 && hz < 57)
      vmax = 580;

   if (height > 300 && hz < 56)
      vmax = 615;
   if (height > 500 && hz < 56)
      vmax = 624;
   if (height > 300)
      pdefault = pdefault * 2;

   vfp = (height + ((vmax - height) / 2) - pdefault) - height;

   if (height < 300)
      vsp = vfp + 3; /* needs to be 3 for progressive */
   if (height > 300)
      vsp = vfp + 6; /* needs to be 6 for interlaced */

   vsp  = 3;
   vbp  = (vmax - height) - vsp - vfp;
   hmax = width + hfp + hsp + hbp;

   if (height < 300)
      pixel_clock = (hmax * vmax * hz);

   if (height > 300)
   {
      pixel_clock = (hmax * vmax * (hz/2)) / 2;
      ip_flag     = 1;
   }

   /* above code is the modeline generator */
   snprintf(set_hdmi_timing, sizeof(set_hdmi_timing),
         "hdmi_timings %d 1 %d %d %d %d 1 %d %d %d 0 0 0 %f %d %f 1 ",
         width, hfp, hsp, hbp, height, vfp,vsp, vbp,
         hz, ip_flag, pixel_clock);

   vcos_init();
   vchi_initialise(&vchi_instance);
   vchi_connect(NULL, 0, vchi_instance);
   vc_vchi_gencmd_init(vchi_instance, &vchi_connection, 1);
   vc_gencmd(buffer, sizeof(buffer), set_hdmi_timing);
   vc_gencmd_stop();
   vchi_disconnect(vchi_instance);
   snprintf(output1,  sizeof(output1),
         "tvservice -e \"DMT 87\" > /dev/null");
   system(output1);
   snprintf(output2,  sizeof(output2),
         "fbset -g %d %d %d %d 24 > /dev/null",
         width, height, width, height);
   system(output2);
   video_driver_reinit(DRIVER_VIDEO_MASK);
}
#endif
