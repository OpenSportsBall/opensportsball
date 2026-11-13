// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** The emails a cloud job sends: the checks are waiting, the video is
 *  ready, or processing failed. Sent through SES from EMAIL_FROM; a stack
 *  without it sends none. A failed send is logged, never thrown: the job's
 *  state matters more than the email about it. */

import { AdminGetUserCommand } from '@aws-sdk/client-cognito-identity-provider';
import { SESv2Client, SendEmailCommand } from '@aws-sdk/client-sesv2';
import type { JobEvent } from './jobs.js';
import { cognito, config } from './store.js';

export const ses = new SESv2Client({});

const TEXT: Record<JobEvent['kind'], { subject: string; body: (link: string, reason: string) => string }> = {
  check: {
    subject: 'Check the pitch for your game',
    body: (link) =>
      `Your game is ready for one quick check: the pitch lines. The video is made once you have answered it.\n\n${link}\n`,
  },
  done: {
    subject: 'Your game video is ready',
    body: (link) => `Your game video is ready to watch and download.\n\n${link}\n`,
  },
  failed: {
    subject: 'Your game could not be processed',
    body: (link, reason) => `Processing your game stopped: ${reason}\n\nYou can start it again from the game's page.\n\n${link}\n`,
  },
};

export async function sendJobEmail({ job, kind }: JobEvent) {
  const from = config.emailFrom;
  const site = config.siteUrl;
  if (!from || !site) return;
  try {
    // The account id is the Cognito username (sign-in is by email alias).
    const user = await cognito.send(new AdminGetUserCommand({ UserPoolId: config.userPoolId, Username: job.accountId }));
    const to = user.UserAttributes?.find((a) => a.Name === 'email')?.Value;
    if (!to) return;
    const link = `${site.replace(/\/+$/, '')}/game?id=${encodeURIComponent(job.gameId)}`;
    const t = TEXT[kind];
    await ses.send(
      new SendEmailCommand({
        FromEmailAddress: from,
        Destination: { ToAddresses: [to] },
        Content: {
          Simple: {
            Subject: { Data: t.subject },
            Body: { Text: { Data: t.body(link, job.error?.message ?? 'an error') } },
          },
        },
      }),
    );
  } catch (e) {
    console.error('could not send the job email', kind, job.jobId, e);
  }
}
